# TP 03 — Retrouver, comparer et qualifier les modèles avec MLflow

© SUPINFO — Auteur : Baptiste DAVID

Prérequis et installation : [guide commun Windows, macOS et Linux](../GUIDE_INSTALLATION.md). - 2026

Ce TP correspond au **chapitre 4 : traçabilité et versions des modèles**.
Prérequis : projet Python du TP1 fonctionnel, workflows PULL et PUSH du TP2, Docker Compose et uv.

## Objectifs du TP

Vos workflows produisent maintenant régulièrement deux modèles : une régression de `pct_pos_total`
et une classification de `estimated_owners`. Trois semaines plus tard, un collègue vous demande :
« Avec quelles données ce modèle a-t-il été entraîné ? Pourquoi celui-ci plutôt que le précédent ? »
Le nom d'un fichier et sa date de modification ne permettent pas de répondre.

Intégrer MLflow à **votre code existant**, puis construire une décision de qualification vérifiable.
À la fin du TP, vous devez savoir :

1. Retrouver le code, les données, les paramètres et les résultats d'un entraînement.
2. Sauvegarder puis recharger les deux modèles complets depuis MLflow.
3. Comparer des versions dans des conditions cohérentes et justifier leur qualification.
4. Automatiser les tags de versions et sélectionner une version par alias, avec retour arrière.

Ce document constitue l'ensemble du support. Vous écrivez le code dans votre projet uv des TP1/TP2 ;
aucun notebook, squelette supplémentaire ou corrigé n'est fourni.

## 1 — Brancher le projet sur le serveur commun

Depuis le dossier du `compose.yml` commun :

```sh
docker compose config --quiet
docker compose up -d --wait --wait-timeout 180 mlflow
docker compose ps mlflow
```

Ouvrir [MLflow local](http://localhost:5000). Le Compose fourni utilise **MLflow 3.16.1**,
SQLite pour les métadonnées et le registre, et un volume persistant pour les artefacts.
Conserver cette version commune pendant le TP. Dans votre projet Python :

```sh
uv add "mlflow==3.16.1"
uv run --locked python -c "import mlflow; print(mlflow.__version__)"
```

Dans chaque terminal qui lance une collecte, le worker PUSH ou une commande de lecture, définir :

```powershell
# PowerShell
$env:MLFLOW_TRACKING_URI = "http://localhost:5000"
$env:MLFLOW_REGISTRY_URI = "http://localhost:5000"
```

```sh
# Linux/macOS
export MLFLOW_TRACKING_URI=http://localhost:5000
export MLFLOW_REGISTRY_URI=http://localhost:5000
```

Adapter le port si vous l'avez changé dans le Compose. Un processus déjà lancé ne reçoit pas ces
nouvelles variables : redémarrer notamment le worker. Depuis un conteneur du même réseau Compose,
l'adresse serait `http://mlflow:5000`. Le code Python reste exécuté sur votre poste dans ce TP.

Créer une expérience propre au binôme, par exemple `5mlde-equipe07-steam`.
Laisser le serveur choisir l'emplacement des artefacts ; ne pas imposer un chemin local du poste client.
Ne pas démarrer un second serveur ni utiliser involontairement un dossier local `mlruns`.

**Objectif :** un run de connexion identifiable apparaît dans l'expérience, avec un petit artefact
que vous pouvez télécharger. Le journaliser comme essai technique, distinct des entraînements.

## 2 — Définir ce qu'il faut pouvoir retrouver

**Situation :** deux fichiers de modèle portent le même nom et leurs scores se ressemblent.
Lister d'abord les questions nécessaires pour choisir et reproduire l'un des deux, puis définir
votre convention de traçabilité. Distinguer paramètres, métriques, tags et artefacts.

Le contrat minimal du TP est le suivant ; compléter les éléments propres à votre implémentation :

| Élément à retrouver | Informations à conserver |
|---|---|
| Déclenchement | `workflow=pull` ou `push`, identifiant d'exécution, date UTC, `batch_id` pour PUSH, numéro de tentative |
| Origine | Source réelle ou `synthetic-course`, appids collectés, dates d'observation, politique de cache et normalisation |
| Données | Snapshot exact, SHA-256 du fichier, schéma, effectifs bruts/retenus/rejetés, raisons des exclusions |
| Préparation | Features, filtres des cibles, classes retenues, paramètres d'imputation et d'encodage, version du prétraitement |
| Reproductibilité | Révision du code, état propre/modifié, sources nécessaires, Python, `pyproject.toml`, `uv.lock`, configuration résolue et graines |
| Apprentissage | Hyperparamètres effectifs des deux modèles et baselines, tailles des partitions, identifiants de split |
| Évaluation | Protocole et empreinte du corpus, métriques par tâche, baselines, effectifs par classe et erreurs par segment |
| Exécution | Durées des étapes, état final, étape et cause d'un échec |
| Livraison | Les deux modèles complets, leur contrat d'entrée, leurs URI MLflow et leurs liens au run |

Un commit seul ne décrit pas du code modifié non committé. Pour le socle, travailler depuis un commit
propre et conserver les sources nécessaires ; si Git n'est pas disponible, archiver ces sources
avec leurs empreintes. Exclure environnements virtuels, caches et secrets des artefacts.

**Objectif :** une convention courte dans votre rapport, permettant à un autre binôme de retrouver
chaque élément sans consulter votre terminal.
**Question :** une URL d'API et la graine aléatoire suffisent-elles à reproduire les données de demain ?

## 3 — Instrumenter les deux workflows

Conserver les quatre fonctions mères du TP1. **`main.py` reste limité à leur enchaînement**.
Placer les opérations MLflow dans un module technique que vous créez, utilisé par les étapes métier.
Les structures échangées entre étapes peuvent porter le contexte de suivi.

Pour limiter la complexité, adopter **un run par tentative d'entraînement des deux modèles**.
Préfixer les paramètres et métriques par tâche pour éviter les collisions, par exemple
`regression.n_estimators`, `classification.n_estimators`, `regression.validation.mae`.
Un nouveau jeu d'hyperparamètres implique un nouveau run ; ne pas tenter de remplacer un paramètre
déjà journalisé dans un run. Utiliser le suivi explicite.

Répartir les responsabilités :

| Étape existante | Travail à ajouter |
|---|---|
| Ingestion | Ouvrir le run avant l'acquisition contrôlée ; conserver configuration, origine et snapshot |
| Prétraitement | Tracer filtres, partitions, statistiques et paramètres de préparation |
| Entraînement | Tracer hyperparamètres, graines et durées, en réutilisant les algorithmes existants |
| Évaluation | Tracer métriques et rapports ; sauvegarder les modèles puis terminer le run après succès |

Si le PUSH réalise l'ingestion avant l'entraînement, relier le run au lot durable et à son snapshot
déjà créé. Ne pas ouvrir 500 runs pour 500 POST. Le worker déclenche le suivi de l'entraînement ;
la requête HTTP continue à répondre sans attendre les forêts.

Transmettre explicitement le `run_id` entre les étapes et dans l'état du job si nécessaire.
Un processus enfant ne partage pas automatiquement le run actif du processus parent.
Prévoir la fermeture en échec depuis chaque étape : aucun run ne doit rester `RUNNING` après une
exception gérée. Une exception doit continuer à signaler l'échec au workflow, sans être avalée.
Le cas d'un arrêt brutal sera traité dans la dernière partie.

### Données traçables et données récupérables

Utiliser `mlflow.data.from_pandas` et `mlflow.log_input` pour associer les jeux aux runs,
avec des contextes distincts, par exemple `training` et `validation`.
Ces métadonnées ne constituent pas une sauvegarde complète du DataFrame : conserver aussi les
snapshots et les listes d'appids des partitions comme artefacts, avec un manifeste SHA-256.
Le digest MLflow et l'empreinte du fichier ne doivent pas être confondus.
[Référence : suivi des datasets](https://mlflow.org/docs/latest/ml/dataset/).

Archiver la projection utile au modèle, pas le CSV original de 471 Mo. Pour le PUSH, le snapshot du
lot reste composé d'exactement **500 jeux**. Les partitions et corpus externes d'évaluation doivent
être identifiés séparément ; ne pas les ajouter au lot d'entraînement.

**Objectif :** un run PULL et un run PUSH permettent de retrouver leurs données et leurs deux tâches.
Pour le PULL, les réponses en cache du TP2 sont utilisables si leur provenance et leur ancienneté
sont explicites. Pour le PUSH, conserver la correspondance `batch_id → run_id`.
**Question :** que perd-on en ne conservant que la métrique finale et le fichier du modèle ?

## 4 — Sauvegarder des modèles réellement rechargeables

Journaliser séparément les deux pipelines ajustés avec `mlflow.sklearn.log_model`.
Inclure toutes les transformations requises à l'inférence, y compris la construction déterministe
des features. Si celle-ci reste une fonction externe, fournir son code et un point d'entrée
d'inférence documenté ; le chargement ne doit dépendre d'aucune variable issue d'un ancien processus.

Pour chacun : fournir un nom distinct, un petit exemple d'entrée sans cible, une signature cohérente
avec l'entrée réellement acceptée, et les dépendances nécessaires. Les colonnes numériques pouvant
contenir des valeurs absentes doivent avoir des types compatibles avec les exemples d'inférence.
Les modules locaux utilisés par un transformeur doivent être importables après récupération.
Choisir explicitement le format de sérialisation et ses dépendances : en 3.16.1, le format par défaut
est `skops`. Avec des transformeurs personnalisés, vérifier les types pris en charge et les éventuels
types de confiance nécessaires au chargement ; documenter un autre format si vous le retenez.
[Référence figée : implémentation scikit-learn en 3.16.1](https://github.com/mlflow/mlflow/blob/v3.16.1/mlflow/sklearn/__init__.py).

Utiliser l'argument `name` et conserver l'URI retournée dans `ModelInfo.model_uri` pour retrouver le
modèle ; ne pas reconstruire cette URI à partir d'un chemin supposé. En MLflow 3, un modèle journalisé
possède aussi sa propre identité : ce n'est pas encore un numéro de version dans le registre.
[Référence : modèles scikit-learn](https://mlflow.org/docs/latest/api_reference/python_api/mlflow.sklearn.html).

Dans un **nouveau processus**, télécharger les modèles depuis MLflow et prédire sur les mêmes
quelques jeux que les pipelines en mémoire. Vérifier l'égalité des classes et une tolérance
numérique explicite pour la régression. Tester également un genre inconnu et une valeur manquante
autorisée par votre contrat. L'exemple d'entrée et la signature documentent ce contrat.
[Référence : signatures et exemples](https://mlflow.org/docs/latest/ml/model/signatures/).

**Objectif :** les deux modèles sont accessibles depuis MLflow et produisent les mêmes prédictions
après rechargement, sans dépendre des anciens fichiers `artifacts/` locaux.

## 5 — Comparer avant de choisir

### Enquête, avant toute règle automatique

Voici un tableau **fictif**, destiné à la discussion ; aucune valeur ne représente un résultat du TP.

| Candidat de classification | Accuracy | F1 macro | Corpus d'évaluation | Autre observation |
|---|---:|---:|---|---|
| A | 0,91 | 0,24 | Steam, référence R1 | Les classes peu fréquentes sont mal reconnues |
| B | 0,79 | 0,52 | Steam, référence R1 | Pipeline rechargeable |
| C | 0,98 | 0,96 | Corpus différent R2 | Moins de classes évaluées |
| D | 0,83 | 0,58 | Steam, référence R1 | Une partie de R1 a servi à l'entraînement |

Individuellement, proposer un candidat à examiner en priorité, les candidats que vous ne pouvez
pas qualifier, et les informations manquantes. Comparer vos décisions en binôme.
Pour une régression, une MAE de 7 et une MAE de 12 sur le même corpus conduiraient-elles au même
raisonnement qu'une accuracy ? Une nouvelle version est-elle nécessairement meilleure ?

### Construire votre protocole de comparaison

Avant les nouveaux essais, figer un corpus de **validation pour la qualification**, issu des données
réelles, avec appids, labels, empreinte et périmètre de classes documentés pour chaque tâche.
Exclure ses appids de l'apprentissage, de l'ajustement du prétraitement et des prochaines collectes
utilisées pour entraîner. Un upsert ne doit pas réintroduire un appid réservé dans train.
Les anciennes versions du TP1 ayant déjà vu ces jeux ne sont pas des candidats comparables :
réentraîner les candidats selon ce nouveau protocole.

Ce corpus sert à sélectionner ; ce n'est plus un test final indépendant. Garder, si possible, un
autre ensemble pour le bilan final, sans ajuster ensuite les seuils sur ce bilan. Ne pas prétendre
qu'une sélection répétée sur la validation donne une estimation non biaisée de la performance future.

Fixer les filtres et l'ensemble de labels de classification à comparer. Ne pas supprimer les classes
difficiles d'une version à l'autre. Rapporter leur support et une politique explicite pour une classe
absente de l'apprentissage. Si les périmètres sont incompatibles, déclarer la comparaison impossible.

Produire au moins **deux nouveaux runs comparables**, soit deux variantes des modèles sur un même
snapshot PULL et les mêmes partitions ; ne modifier qu'un ou deux hyperparamètres. Le run PULL de la
partie 3 peut être réutilisé s'il respecte déjà ce protocole. Comparer :

- Régression : MAE en points de pourcentage, RMSE, R² et baseline du TP1.
- Classification : accuracy, F1 macro, rapport par classe, matrice de confusion et baseline.
- Pour les deux : effectifs, temps d'entraînement et réussite du rechargement.

Tracer séparément les métriques de validation commune et celles du test interne de chaque run.
La baseline est ajustée sur le train de la variante puis évaluée sur le même corpus de validation.

**Cas PUSH :** les labels aléatoires du simulateur ne constituent pas une preuve de qualité sur Steam.
Conserver ses modèles pour démontrer le workflow, dans un périmètre de démonstration identifié.
Des scores sur un autre corpus, avec d'autres classes, ne se comparent pas directement à ceux du PULL.

**Objectif :** un tableau issu de vos vrais runs, contenant leurs identifiants et empreintes de validation,
avec une conclusion argumentée par tâche. L'absence de candidat satisfaisant est une conclusion valide.

## 6 — Versionner et automatiser une qualification

### Du modèle sauvegardé à sa version

Créer deux noms stables dans le Model Registry pour les modèles réels du binôme, un par tâche.
Créer deux autres noms explicitement suffixés `-demo` pour les modèles synthétiques du PUSH.
Le nom ne doit pas contenir la date ou les hyperparamètres : les nouveaux entraînements créent des
**versions** sous le même nom. Les baselines restent des éléments de comparaison dans les runs.

Enregistrer au moins deux versions de chacun des modèles réels, puis une version de chacun des
modèles de démonstration. Utiliser le numéro retourné par le registre : ne pas supposer qu'il vaut
1 ou qu'il est identique pour les deux tâches. Relier chaque version à son run, son URI de modèle,
son snapshot et son protocole. Une version enregistrée n'est pas automatiquement qualifiée.

### À vous de proposer la règle

À partir de la partie 5, écrire une politique de décision **avant de qualifier les candidats**.
Proposer les métriques pertinentes, leur sens d'amélioration, les seuils et les motifs de refus.
Justifier les seuils au regard des baselines et d'un objectif métier pédagogique que vous formulez.
Ne pas déplacer un seuil après chaque résultat pour faire passer le dernier modèle.

La politique doit répondre aux situations suivantes, sans imposer que vos deux tâches aient la même décision :

- Une version améliore la métrique principale mais dégrade fortement certaines classes ou un segment.
- Une version est meilleure que la baseline mais reste insuffisante pour l'usage proposé.
- Une métrique manque, n'est pas finie, ou provient d'un protocole incompatible.
- Un modèle donne un bon score mais ne peut pas être rechargé correctement.
- Un modèle a été entraîné sur les données artificielles du PUSH.

Choisir un vocabulaire de tags, par exemple une clé `qualification` prenant les valeurs `pending`,
`production-ready`, `rejected` ou `demo-only`. Vous pouvez proposer d'autres libellés si leur sens
est explicite. Dans ce TP, **`production-ready` signifie uniquement que votre politique pédagogique
est satisfaite** ; cela ne remplace pas une validation métier, opérationnelle et de sécurité réelle.

Versionner la politique avec votre code : identifiant, seuils, métriques, empreinte du corpus admis,
règles de provenance et contrôles techniques. Implémenter une fonction de décision testable qui
consomme les résultats d'évaluation déjà calculés. Elle ne réentraîne pas le modèle.

Appliquer ensuite automatiquement les **tags de version de modèle**, en conservant également la
version de politique, la date et le motif. Journaliser dans le run un rapport de décision contenant
valeurs observées, seuils et résultat de chaque contrôle. Un simple tag de run ne qualifie pas
automatiquement une version du registre. Les tags étant modifiables, conserver chaque nouvelle
évaluation dans un rapport distinct, sans écraser les preuves précédentes.

### Tag, version et alias : trois rôles

Une version identifie un modèle enregistré. Un tag décrit cette version. Un alias désigne une version
et peut être réaffecté ; plusieurs versions peuvent partager un même tag de qualification.
Utiliser les tags et alias actuels, pas les anciens stages `Staging`/`Production` dépréciés.
[Référence : workflows du registre](https://mlflow.org/docs/latest/ml/model-registry/workflow/).

**Objectif :** la qualification est calculée depuis les résultats et attachée aux bonnes versions.
Tester au minimum un cas accepté et un cas refusé au moyen de résultats de test contrôlés, clairement
distincts des métriques réelles MLflow. Si aucun vrai candidat ne satisfait la politique, ne pas
inventer de métriques et ne pas le qualifier artificiellement.

## 7 — Sélectionner, recharger et revenir en arrière

Proposer une commande distincte de sélection, écrite par vos soins. Elle reçoit un nom de modèle
et un numéro de version, vérifie la qualification avec la politique courante et les preuves associées,
puis positionne un alias tel que `champion`. Un tag saisi manuellement ne suffit pas à autoriser ce choix.
La qualification automatique d'une version et la décision de remplacer le modèle sélectionné sont
deux opérations distinctes ; un seuil absolu satisfait ne prouve pas que le candidat bat l'actuel.

Charger la version sélectionnée avec une URI de la forme `models:/<nom>@champion`, puis retrouver
son numéro concret. Comparer avec un chargement par `models:/<nom>/<version>`.
Ces références et les méthodes de gestion d'alias sont documentées dans le
[client MLflow](https://mlflow.org/docs/latest/api_reference/python_api/mlflow.client.html).

Conserver une trace de chaque sélection : alias, ancienne et nouvelle versions, acteur, date,
motif et rapport de qualification. Tester un retour à la version précédemment sélectionnée.
Un changement d'alias ne recharge pas un objet déjà présent en mémoire : vérifier le résultat dans
un nouveau processus. Aucun service de prédiction à déployer n'est demandé ici.

Si vous n'avez pas deux versions réelles qualifiées, réaliser uniquement la mécanique d'aller-retour
avec un alias `demo-current` sur deux versions de démonstration. Ne pas abaisser vos critères pour
obtenir un `champion`. La sélection réelle peut légitimement rester absente.

Les deux modèles évoluent indépendamment. Si vous souhaitez les livrer ensemble, conserver un
manifeste contenant leurs deux numéros précis et vérifier que les deux sont qualifiés ; deux
changements d'alias successifs ne constituent pas une transaction atomique.

**Objectif :** chargement par numéro et par alias, refus d'un candidat inéligible, historique de sélection
et retour arrière. Le modèle utilisé et sa provenance peuvent être retrouvés sans ouvrir votre code.

## 8 — Incidents et audit croisé

Réaliser les vérifications suivantes sur votre intégration, avec les anciens modèles conservés :

| Incident ou contrôle | Résultat à démontrer |
|---|---|
| Donnée invalide ou échec d'une tâche | Run en échec avec cause ; aucune sélection ni qualification positive nouvelle |
| Rapport incomplet ou corpus incompatible | Qualification refusée ou laissée en attente avec motif, alias inchangé |
| Nouvelle version moins bonne selon la politique | Version conservée pour analyse, tag justifié, alias inchangé |
| Serveur MLflow indisponible | Erreur explicite du workflow ; aucun succès de publication annoncé |
| Reprise d'un lot PUSH déjà publié | Pas de nouvelle version dupliquée pour cette même publication |
| Redémarrage normal du conteneur MLflow | Runs et modèles encore consultables et téléchargeables |

Pour simuler l'indisponibilité : depuis le dossier du Compose, utiliser `docker compose stop mlflow`,
puis `docker compose up -d --wait mlflow` pour reprendre. Ne pas supprimer les volumes.
Dans le socle, une panne de suivi bloque la publication ; il n'est pas demandé de construire une
file d'attente hors ligne. Un run ne peut pas être marqué `FAILED` à distance pendant cette panne :
conserver le diagnostic local et réconcilier son état après reprise.

Les écritures d'artefacts, l'enregistrement des deux versions et le changement de tags ne forment pas
une transaction globale. Une publication partielle reste identifiable et non qualifiée jusqu'à
réconciliation. Persister les identifiants déjà obtenus ; avant une reprise, rechercher les versions
liées à cette publication. Distinguer une reprise technique d'un nouvel entraînement intentionnel.
Après un arrêt brutal, détecter les runs ou jobs restés ouverts et documenter leur traitement.

Enfin, échanger un **nom de modèle et un numéro de version** avec un autre binôme, sur le poste où
le serveur est accessible. Sans explication orale, il doit retrouver les données, le code, les
hyperparamètres, le rapport d'évaluation et la raison du tag, puis recharger et utiliser le modèle.

**Objectif :** compte rendu bref avec identifiants de runs/versions, commandes, états avant/après et
résultats de tests. Les captures de l'interface complètent ces preuves sans les remplacer.

## Livrables et critères de réussite

- Projet Python TP1/TP2 enrichi, tests, dépendances uv verrouillées et procédure de reprise.
- Au moins deux entraînements réels comparables et un entraînement PUSH tracé, chacun avec les deux tâches.
- Snapshots récupérables, empreintes, partitions, code et paramètres reliés aux runs.
- Deux modèles réels versionnés et deux modèles de démonstration identifiés, tous rechargeables.
- Politique de qualification versionnée, tags automatiques, rapports explicatifs et tests des refus.
- Preuves de sélection par alias, retour arrière, incidents et audit croisé ; signaler si aucune version
  réelle ne mérite une qualification positive.

L'évaluation porte sur la traçabilité, la validité du raisonnement et la fiabilité du logiciel,
pas sur l'obtention à tout prix d'un tag `production-ready` ou d'un score arbitraire.

## Indices graduels et références

1. Commencer par un run explicite et quelques champs ; étendre ensuite aux artefacts et aux deux workflows.
2. Séparer la décision de qualification de ses effets dans MLflow facilite les tests de seuils et de refus.
3. Explorer `start_run`, `log_params`, `log_metrics`, `log_artifacts` et les méthodes du client acceptant
   un `run_id` explicite : [suivi d'expériences](https://mlflow.org/docs/latest/ml/tracking/).
4. Explorer `register_model`, `set_model_version_tag`, `set_registered_model_alias` et
   `get_model_version_by_alias`, sans les confondre avec les tags du run.
5. Garder un identifiant de publication stable et les versions déjà créées permet de raisonner sur une reprise.

Les pages `latest` évoluent : la référence
d'exécution de la séance reste le client et le serveur **3.16.1** du Compose commun. Vérifier les
signatures disponibles dans cet environnement avant de reprendre un exemple de documentation.
