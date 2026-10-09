# TP 01 — Du carnet exploratoire à deux modèles réutilisables
© SUPINFO — Auteur : Baptiste DAVID

Prérequis et installation : [guide commun Windows, macOS et Linux](../GUIDE_INSTALLATION.md). - 2026

Prérequis : Python (fonctions, modules, exceptions), pandas et principes train/test du ML.
Git est utile mais la revue entre pairs peut se faire sans plateforme distante.

## Objectifs du TP
Une équipe a exploré un catalogue Steam dans `exploration_steam.ipynb`. Elle obtient des résultats,
mais ne sait pas livrer séparément ses deux modèles ni reproduire les entraînements.
Vous devez transformer ce brouillon en un projet Python lançable depuis un terminal.

1. Régression : estimer `pct_pos_total`, le pourcentage d’avis positifs (0 à 100).
2. Classification multiclasse : prédire le libellé exact d’une tranche `estimated_owners`.

`estimated_owners` désigne des propriétaires estimés, pas des joueurs actifs.
Le premier chapitre motive les besoins MLOps ; ce TP anticipe, à la demande de l’enseignant,
la modularisation du chapitre 2. Aucun acquis de MLflow, Prefect ou du déploiement n’est requis.

### Compétences à démontrer
- Relier quatre défauts observés à la reproductibilité, la maintenance ou l’exploitation.
- Extraire des fonctions réutilisables et isoler configuration, données et entraînement.
- Produire et recharger deux pipelines complets, avec des métriques interprétables.
- Prouver par des tests qu’une entrée invalide bloque le traitement sans altérer les artefacts.

## Préparer le poste
**uv est le gestionnaire recommandé**, avec Python **3.12**. Installer uv si nécessaire en suivant
[la documentation officielle](https://docs.astral.sh/uv/getting-started/installation/).
Depuis ce dossier, sous Windows, Linux ou macOS :

```sh
uv python install 3.12
uv sync --locked
uv run --locked jupyter lab exploration_steam.ipynb
```

`uv sync` crée `.venv` et installe les dépendances verrouillées ; aucune activation manuelle n’est nécessaire.
`uv run` lance une commande dans cet environnement. Le groupe `dev` est installé par défaut.
Choisir le kernel Python de cet environnement dans Jupyter.
Le `pyproject.toml` exprime les dépendances directes, `uv.lock` fixe aussi les dépendances transitives,
`.python-version` demande Python 3.12. Le lockfile ne fige pas à lui seul la version corrective de Python ni le système.
Consigner la version de Python réellement utilisée dans votre rapport.
`--locked` refuse un verrou obsolète : après un changement intentionnel de dépendance, utiliser
`uv add nom-du-paquet` (ou `uv add --dev nom-du-paquet`), puis versionner `pyproject.toml` et `uv.lock`.
Ne pas lancer `uv lock --upgrade` pendant la séance sans raison : cela change l’environnement de référence.

Jupyter utilise normalement le port local 8888 ; arrêter avec Ctrl+C. Aucun compte ni GPU nécessaire.
Prévoir environ 2 Go d’espace pour l’environnement et quelques Go de RAM disponibles.

Les CSV ne sont pas inclus dans le dépôt Git. Suivre la partie « Télécharger et préparer le dataset Steam »
du [guide d'installation](../GUIDE_INSTALLATION.md) pour récupérer le CSV complet sur Kaggle et générer
`data/games.csv` : une projection de **94 948 lignes**, sans échantillonnage, pour la version de référence.
Le manifeste donne les colonnes et les empreintes de référence. Après préparation, le notebook utilise la projection.
Voir `data/DICTIONNAIRE.md` pour les conventions.

## 1 — Constater les problèmes
**Problème :** le notebook fonctionne, mais son état est fragile.
Exécuter « Restart Kernel and Run All ». Relever MAE, R², accuracy et F1 macro, ainsi que les baselines.
Faire la manipulation de réexécution sélective indiquée à la fin ; redémarrer ensuite le kernel.
Relancer tout : noter la variation des métriques et identifier les sources d’aléatoire.
Examiner les exports et retrouver le type du modèle sauvegardé.

**Objectif :** un tableau « symptôme → cause → conséquence métier → correction », au moins six lignes.
**Question :** avoir une métrique correcte suffit-il à livrer les deux usages ?

## 2 — Écrire le contrat avant d’extraire
**Problème :** les choix métier et les paramètres sont dispersés.
Rédiger un contrat court : entrées autorisées, cibles, filtres, split, sorties, incidents.
Conserver les choix de modélisation du notebook pour ce TP ; ne pas chercher à optimiser les scores.
La classification conserve les tranches d’origine ; le périmètre exclut `0 - 0` et les classes de moins de 5 jeux.
La régression conserve les pourcentages valides avec au moins 10 avis.
Ne pas remplacer les valeurs de cible indisponibles par zéro.

**Objectif :** diagramme simple du traitement et responsabilités des modules ; configuration JSON
contenant chemin des données, dossier de sortie, graine, seuils et hyperparamètres.
**Question :** pourquoi ne pas utiliser `positive`, `negative`, les colonnes d’audience ou l’autre cible comme features ?

## 3 — Extraire le code
**Problème :** copier-coller et variables partagées empêchent une évolution sûre.
Compléter exactement les quatre modules du squelette fourni :

```text
main.py                         # fourni entièrement : orchestration
src/
  __init__.py
  ingestion.py                  # load_data(config_path)
  preprocessing.py              # preprocess_data(data)
  training.py                   # train_models(prepared_data)
  evaluation.py                 # evaluate_models(trained_models)
```

| Fonction mère | Responsabilité | Contrat de sortie à documenter |
|---|---|---|
| `load_data` | Lire la configuration et le CSV ; vérifier la présence des colonnes, résoudre les chemins depuis la configuration | Données brutes et configuration, y compris la destination des artefacts |
| `preprocess_data` | Contrôler les valeurs et doublons, appliquer les filtres des deux tâches, construire les features, séparer train/test, ajuster imputation et encodage sur train uniquement | Pour chaque tâche : train/test, identifiants, prétraitement ajusté ; configuration conservée |
| `train_models` | Ajuster les deux modèles et leurs baselines sur train | Modèles, baselines, prétraitements, données de test et configuration conservés |
| `evaluate_models` | Prédire sur test, calculer les métriques et publier les artefacts après succès des deux tâches | Rapport et chemins des artefacts |

Les fichiers fournis contiennent uniquement les fonctions mères à implémenter. Choisir une structure
explicite pour transmettre les résultats (dictionnaire ou dataclass), en évitant les variables globales.
Ajouter les fonctions auxiliaires dans le module correspondant. Le `main.py` est déjà complet :
il appelle seulement les quatre fonctions dans l'ordre. Il ne doit contenir ni nettoyage, ni split,
ni `fit`, ni calcul de métriques, ni export. La lecture des arguments du terminal est déjà fournie.

Le notebook initial contient maintenant un audit des types, valeurs absentes, sentinelles, doublons et valeurs extrêmes ;
le nettoyage des genres (espaces, casse, doublons), les indicateurs de genres, `log1p` sur les distributions asymétriques,
les indicateurs de plateformes, le codage cyclique du mois, l'imputation avec indicateurs de manque et le regroupement
sans fuite des catégories rares. Extraire ces décisions dans `preprocessing.py` et expliquer chacune.
Conserver les valeurs extrêmes valides ; une transformation logarithmique ne garantit pas un gain pour une forêt.
`min_frequency=10` et les médianes sont appris sur train exclusivement ; `infrequent_if_exist` gère les catégories inconnues.
Les transformations déterministes peuvent précéder le split ; leurs paramètres appris, jamais.
Utiliser une graine explicite pour les splits et les forêts. Garder le prétraitement ajusté avec chaque modèle,
sans le réajuster sur le test ou à l'inférence.

Une fois les fonctions complétées, la commande commune à ce TP et aux suivants est :

```sh
uv run --locked python main.py --config config.json
```

Créer vous-mêmes `config.json` : source CSV, dossier de run neuf, graine, taille du test, seuils et hyperparamètres.
À ce stade, le squelette non complété lève volontairement `NotImplementedError` ; ce n'est pas un projet terminé.

**Objectif :** une commande entraîne les deux modèles sans ouvrir Jupyter.
Les chemins doivent être résolus depuis le fichier de configuration, pas depuis le dossier courant.
Les artefacts ont des noms distincts : `regression.joblib`, `classification.joblib`, `metrics.json`,
`split_regression.csv`, `split_classification.csv`, `config.json` et `manifest.json`.
Les CSV de split indiquent `appid` et `train`/`test` ; les métriques donnent aussi les effectifs,
classes exclues, baseline et rapport par classe. Sauvegarder les pipelines incluant le prétraitement.

**Question :** pourquoi sauvegarder uniquement la forêt ne suffit-il pas ?

## 4 — Rendre la livraison vérifiable
**Problème :** un export ne prouve ni sa réutilisabilité ni l’absence de fuite.
Ajouter une commande de prédiction qui recharge les deux modèles, prend un CSV de métadonnées
sans les cibles et écrit `appid`, `pct_positive_pred` et `estimated_owners_pred`.
Écrire au minimum six tests de comportement :
1. Colonne indispensable absente : erreur claire.
2. Entrée numérique invalide (`price = "gratuit"`) : entraînement refusé.
3. Genre jamais vu à l’entraînement : prédiction possible.
4. Aucun identifiant partagé entre train et test pour chaque tâche.
5. Prédictions identiques avant/après sérialisation pour chacun des deux pipelines.
6. Valeurs manquantes, catégories rares et inconnues : transformations ajustées seulement sur train ; dimensions cohérentes à l’inférence.

**Objectif :** `uv run --locked python -m pytest -q` réussit ; une inférence fonctionne dans un nouveau processus.
La régression renvoie des nombres dans [0, 100] et la classification seulement des labels du périmètre appris.
**Question :** pourquoi le F1 macro apporte-t-il une information différente de l’accuracy ?

## 5 — Incident et reprise par un collègue
**Problème :** une exécution défaillante pourrait écraser des modèles valides.
Créer une copie de 50 lignes avec `price = "gratuit"` sur une ligne. Conserver le CSV original intact.
Pointer une configuration vers cette copie et lancer le traitement avec un dossier de sortie neuf.
Attendre un code de sortie non nul et aucun artefact de modèle ou métrique dans ce dossier.
Vérifier aussi qu’un dossier de run déjà existant est refusé sans modification.
Comparer les empreintes des anciens modèles avant/après l’incident.
Une catégorie inconnue est un cas accepté ; un prix non numérique est un incident bloquant : distinguer les deux.

Transmettre le projet à un binôme : il doit installer les dépendances, exécuter les tests,
entraîner puis prédire en suivant uniquement le README. Exécuter deux fois avec la même configuration
et des dossiers distincts ; comparer les splits, métriques et prédictions (tolérance numérique 1e-10),
sans exiger l’identité binaire des fichiers joblib.

**Objectif :** transcript des commandes, codes de sortie, contrôles des fichiers et explication de la reprise.
**Question :** qu’apporterait ensuite une CI pour éviter une régression logicielle ?

## Livrables
- Notebook original conservé et diagnostic ; projet Python modulaire avec configuration, `pyproject.toml`, `uv.lock` et `.python-version`.
- Tests, README permettant une reprise sans aide, rapport bref avec métriques des deux tâches et limites.
- Preuves du cas nominal, de reproductibilité, de rechargement et de l’incident.
- Si Git est disponible : au moins trois commits cohérents (diagnostic, extraction, tests) ; ne pas committer données,
  environnement virtuel ni modèles. Versionner en revanche `uv.lock`. Sinon fournir une archive du code et expliquer les étapes de modification.

L’évaluation porte sur le comportement du logiciel et les justifications, pas sur un seuil de score.
Les classes rares sont difficiles ; aucune promesse de performance de production n’est attendue.

## Indices graduels
1. Commencer par entourer les blocs du notebook correspondant à une responsabilité ; écrire leurs entrées/sorties.
2. Faire retourner un DataFrame de features sans cible ; éviter qu’une fonction lise une variable globale.
3. Un `Pipeline` sérialisé conserve l’imputation et l’encodage ; un `ColumnTransformer` fixe les colonnes attendues.
4. Pour les effets persistants : valider, entraîner, puis écrire dans un dossier temporaire avant publication du run.
