# TP 02 — Qui décide de lancer l’entraînement ?
© SUPINFO — Auteur : Baptiste DAVID

Prérequis et installation : [guide commun Windows, macOS et Linux](../GUIDE_INSTALLATION.md). - 2026

Prérequis : projet TP1 terminé (régression et classification, CLI, tests, artefacts), bases HTTP/JSON,
uv et notion de transaction SQL. Une introduction à SQLite peut être faite avant la seconde séance.
Ce TP porte sur les sources dynamiques du chapitre 3 ; la numérotation suit les séances de TP.

## Objectifs du TP 
Le projet Python ne doit plus dépendre uniquement d’un CSV figé. Faire évoluer votre projet du TP1 pour :
1. Acquérir et normaliser des observations issues de plusieurs réponses d’API.
2. Construire un dataset versionné sans dupliquer les jeux ou mélanger silencieusement les définitions.
3. Déclencher le même entraînement par une collecte active ou un événement externe.
4. Valider les données avec Great Expectations et interrompre le pipeline en cas de non-conformité,
   puis vérifier doublons, seuils, erreurs et reprise sans altérer les anciens modèles.

Conserver les deux modèles, leurs variables explicatives et leur logique de préparation.
Reprendre les quatre modules `ingestion.py`, `preprocessing.py`, `training.py` et `evaluation.py`,
et le `main.py` produit au TP1. Le nouveau mode d'acquisition rejoint l'ingestion ; la préparation,
l'entraînement et l'évaluation restent réutilisables. **Aucun notebook n'est utilisé à partir de ce TP.**
Aucun corrigé ni client API complet n'est fourni : vous implémentez les étapes décrites ici.

## Comparer les deux workflows

| | Actif — pull | Passif — push |
|---|---|---|
| Initiateur | Votre commande Python de collecte | Un producteur externe envoie les jeux |
| Données | APIs Steam Store + SteamSpy, puis upsert dans la base TP1 | Un POST par jeu ; exactement 500 jeux par lot |
| Condition de départ | Collecte demandée complète et dataset valide | Seuil atteint sur les jeux acceptés non affectés |
| Entraînement | Même point d’entrée TP1 | Même point d’entrée TP1 |
| Preuve | Sources, snapshot, métriques et artefacts | 499/500/501, état du job et deux artefacts |

« Actif » et « passif » qualifient ici l’origine du déclenchement, pas l’active learning.
Le parcours passif est une ingestion événementielle avec entraînement **par micro-lots**, pas un modèle
qui apprend en continu après chaque observation. L’acteur externe contrôle l’arrivée des données ;
le collecteur décide de réserver un lot selon la règle des 500.

## Installation et réutilisation
Travailler dans le projet uv créé au TP1 et conserver son `pyproject.toml` et son `uv.lock`.
Ajouter les dépendances utiles dans ce projet, par exemple `uv add httpx fastapi uvicorn`, puis versionner le verrou.
Pour la validation, ajouter **GX Core**, le SDK Python open source de Great Expectations :

```sh
uv add "great-expectations==1.23.2"
uv run --locked python -c "import great_expectations as gx; print(gx.__version__)"
```

Cette version est publiée sur [PyPI](https://pypi.org/project/great-expectations/1.23.2/) et documentée
dans la branche GX Core 1.x. Conserver Python 3.12 et versionner le verrou
résolu par uv ; aucun compte GX Cloud ni service Docker supplémentaire n'est nécessaire.
Le simulateur fourni utilise uniquement la bibliothèque standard Python et n'exige aucun paquet supplémentaire.
Copier `simulateur_push.py` et le dossier `api_trigger_passif/` à la racine de votre projet TP1.
Conserver le Compose commun ; depuis son dossier : `docker compose up -d --wait`.
La nouvelle API écoute sur **127.0.0.1:8000**.
Ce TP travaille sur le déclenchement et la qualité des données ; les TPs suivants intégreront ces services.

Le seul point d'entrée de l'entraînement reste :

```sh
uv run python main.py --config config.json
```

Étendre la configuration du TP1 pour sélectionner la source, les appids à collecter, le cache et un dossier de sortie neuf.
Le `main.py` doit continuer à chaîner seulement les quatre fonctions mères ; les choix d'acquisition restent dans `ingestion.py`.

**Objectif :** une ligne normalisée peut devenir un CSV lisible par votre module de données TP1.    
**Question :** quel contrat doit rester stable entre acquisition et entraînement ?

## Partie Q — Tester les données avant de les préparer

### Q1. Définir le contrat sous forme d'expectations

**Problème :** un JSON conforme et un CSV lisible peuvent encore contenir des doublons, des labels
impossibles ou un lot insuffisant pour entraîner les deux modèles.

Créer **avec le SDK Python Great Expectations** une ou plusieurs `ExpectationSuite` nommées et
versionnées. Les expectations doivent formaliser vos prérequis, pas seulement décrire ce que vous
observez dans les données du jour. Ne pas les générer automatiquement puis tout accepter sans examen.
Une suite est un ensemble de règles ; les petits jeux de données utilisés pour tester ces règles
seront construits séparément par vos soins.
[Référence : suites d'expectations](https://docs.greatexpectations.io/docs/core/define_expectations/organize_expectation_suites/).

Définir au minimum les familles de contrôles suivantes :

| Famille | Prérequis à traduire en expectations |
|---|---|
| Structure | Présence des features et cibles indispensables au contrat TP1, même si certaines valeurs peuvent manquer |
| Identité | `appid` entier positif, non nul et unique dans le snapshot complet |
| Valeurs numériques | Prix et comptages non négatifs lorsqu'ils sont renseignés ; pas de texte comme « gratuit » ni d'infini |
| Types et formats | Plateformes booléennes, genres et dates conformes au contrat de la source |
| Cibles des nouveaux jeux | `pct_pos_total` fini entre 0 et 100, au moins 10 avis, tranche de propriétaires valide |
| Volumétrie | Corpus non vide ; exactement 500 lignes pour le snapshot du lot PUSH |
| Aptitude à entraîner | Effectifs admissibles pour la régression, au moins deux classes retenues et effectifs compatibles avec le split du TP1 |

Pour les bornes d'une tranche, vérifier aussi l'ordre des deux nombres : une regex seule ne détecte
pas `50000 - 20000`. Pour les nulls, écrire les expectations de présence là où elles sont nécessaires :
une règle de plage peut ignorer les valeurs absentes et ne suffit donc pas à les interdire.
Une valeur manquante autorisée, comme un prix indisponible, doit rester acceptée pour l'imputation du TP1.

**Attention au CSV historique :** il contient `required_age=-1`, `pct_pos_total=-1`, des tranches
`0 - 0`, des classes rares et quelques noms ou dates manquants. Le TP1 possède des conventions
explicites pour ces cas. Ne pas appliquer aveuglément le contrat strict des nouveaux POST aux
94 948 lignes historiques, et ne pas supprimer ces lignes avant validation pour cacher un échec.

Prévoir un socle de contrôles sur le corpus complet et des règles plus strictes sur les nouveaux
jeux normalisés, identifiés par leur provenance. Documenter les sentinelles historiques admises,
sans les étendre aux données nouvellement collectées. Valider les nouveaux jeux **avant l'upsert**,
puis valider le snapshot final : une règle stricte ne doit pas disparaître lors du mélange des sources.

Pour contrôler l'aptitude du lot avant prétraitement, calculer seulement les effectifs qui seraient
éligibles selon les filtres du TP1, sans transformer le dataset. Une petite table d'audit validée
par une suite GX permet de vérifier ces nombres. Conserver les mêmes règles d'éligibilité que le
prétraitement ; vérifier notamment les tailles train/test nécessaires au split stratifié.
Les attentes sur un lot complet ne s'appliquent pas à la petite collecte PULL de 1 à 10 nouveaux jeux.

Toutes les expectations de prérequis sont **bloquantes** dans le socle. Ne pas utiliser un seuil
`mostly` inférieur à 1 pour tolérer des identifiants dupliqués ou des cibles invalides. Des statistiques
informatives peuvent compléter le rapport, mais ne doivent pas être confondues avec ces prérequis.

**Objectif :** un tableau « règle métier → expectation → périmètre → traitement des nulls/sentinelles »
et des suites créées par Python. Les cas autorisés et bloquants doivent être justifiés.

### Q2. Exécuter la validation et bloquer la chaîne

Créer un helper de validation dans votre projet, par exemple dans `src/data_validation.py`.
**L'appeler à la fin de `load_data`, avant son retour et donc avant tout appel à `preprocess_data`.**
Le `main.py` conserve ses quatre fonctions mères ; aucune cinquième étape n'y est ajoutée.

```text
load_data : acquisition → normalisation du format → snapshot candidat → validation GX
                                                          │
                                     succès de tous les contrôles requis
                                                          ↓
preprocess_data → train_models → evaluate_models

Échec de validation ou erreur GX → rapport de rejet → exception → arrêt du pipeline
```

La normalisation du format d'entrée appartient à l'ingestion : déballer le JSON, convertir les
centimes ou parser une représentation reconnue est nécessaire pour comparer les sources.
Elle ne doit pas transformer une valeur invalide en null silencieusement. L'imputation, le nettoyage
des features, leur encodage, le split et tout `fit` restent **après** la barrière de validation.

Avec le SDK GX Core 1.x, construire un Data Context, une source Pandas, un Data Asset et une Batch
Definition pour recevoir le DataFrame en mémoire. Associer la Batch Definition à la suite dans une
`ValidationDefinition`, puis l'exécuter avec le DataFrame de ce run. Les points d'entrée à explorer
sont `gx.get_context`, `context.data_sources.add_pandas`, `add_dataframe_asset`,
`add_batch_definition_whole_dataframe` et `gx.ValidationDefinition`.
[Référence : connexion à un DataFrame](https://docs.greatexpectations.io/docs/core/connect_to_data/dataframes/).

Examiner **explicitement** `validation_result.success` : lancer GX ne suffit pas à interrompre le
programme. En cas de résultat négatif, lever une exception métier après conservation du diagnostic.
Une erreur d'exécution de GX ou l'absence de résultat valide bloque aussi le pipeline ; elle ne vaut
jamais autorisation d'entraîner. Si plusieurs suites sont requises, elles doivent toutes réussir.
[Référence : exécution d'une Validation Definition](https://docs.greatexpectations.io/docs/core/run_validations/run_a_validation_definition/).

Conserver un rapport lisible et exploitable : date, source, empreinte du snapshot, nom/version des
suites, succès global, contrôles en échec et quelques appids concernés. En cas d'erreur technique,
conserver sa cause et les contrôles qui n'ont pas pu être évalués.
Les rapports de validation et snapshots rejetés vont dans un emplacement de diagnostic distinct
des modèles et métriques d'évaluation. Ne pas confondre ce rapport avec un entraînement réussi.

Valider le snapshot entier, pas seulement un échantillon. Transmettre ensuite exactement les données
validées : ne pas relire un fichier mutable susceptible d'avoir changé entre validation et traitement.

- **PULL :** échec GX → code de sortie non nul ; aucun prétraitement ni entraînement des deux modèles.
- **PUSH :** le POST peut avoir été accepté individuellement, mais le worker valide ensuite le lot
  complet. Échec GX → job `FAILED`, motif et rapport accessibles ; aucun prétraitement ni entraînement.
  Le lot reste réservé et identifiable, et l'API peut continuer à recevoir les suivants.

La validation du POST et la validation GX du lot sont complémentaires. Ne pas réécrire rétroactivement
la réponse HTTP du 500e POST ; elle signifie toujours « accepté », pas « modèles entraînés ».
Ne pas rejouer en boucle un lot invalide inchangé. Une correction doit être traçable et revalidée.

**Objectif :** un résultat GX négatif stoppe effectivement l'exécution avant le prétraitement.
**Question :** pourquoi un rapport rouge, sans exception ni branchement bloquant, ne protège-t-il pas le modèle ?

### Q3. Tester les tests de données

Construire de petits datasets dans vos tests Python, en partant d'un cas conforme puis en modifiant
une seule condition à la fois. Utiliser aussi un lot de 500 jeux pour les contrôles propres au PUSH.

| Cas contrôlé | Résultat attendu |
|---|---|
| Données conformes, avec un null explicitement autorisé | Suites réussies ; pipeline autorisé |
| Colonne requise absente, appid nul ou dupliqué | Rejet avant prétraitement |
| `price="gratuit"` ou pourcentage nouveau jeu à 120 | Rejet avec cause identifiable |
| Sentinelle historique admise | Acceptation du contrat historique, exclusion métier ultérieure si prévue |
| Même sentinelle dans un nouveau jeu où elle est interdite | Rejet de la nouvelle collecte ou du lot |
| Snapshot PUSH de 499 lignes ou lot de 500 jeux d'une seule classe retenue | Rejet des prérequis du lot |
| Exception GX ou résultat absent | Échec bloquant, jamais un passage implicite |

Utiliser des spies/mocks pour prouver que `preprocess_data`, `train_models` et `evaluate_models`
ne sont **pas appelées** après un rejet. Tester les deux chemins PULL et PUSH et contrôler aussi
les effets persistants : aucun nouveau modèle ni métrique d'évaluation, et empreintes des anciens
modèles inchangées. Le rapport de rejet, lui, doit exister.

**Objectif :** tests automatisés, rapport GX réussi et rapport rejeté, code de sortie PULL et état du job PUSH.
Dans les TPs suivants, conserver cette barrière ; MLflow pourra stocker les rapports et Prefect
observer l'échec sans retenter une non-conformité métier inchangée.

## Partie A — Aller chercher les données

### A1. Explorer les réponses et choisir le mapping
Consulter les trois endpoints pour un appid choisi parmi 620, 400 et 550, puis lire [le contrat des sources ci-dessous](#api-retenues). Expliquer pourquoi aucune source
ne fournit seule toutes les colonnes retenues au TP1. Construire une fonction de normalisation qui renvoie une ligne validée.
Vérifier l’identité, les prix en centimes, la devise, les dates, les booléens, le résumé d’avis et les tranches.

**Objectif :** trois lignes validées ; tests d’un jeu gratuit, d’un prix absent et d’un label indisponible.    
**Question :** pourquoi `review_score` et `num_reviews` ne sont-ils pas les colonnes cibles recherchées ?

### A2. Remplacer la lecture statique par un client HTTP
Créer un client avec timeout, statut HTTP vérifié, cache et trois tentatives au maximum sur panne transitoire.
Espacer les appels et respecter `Retry-After`. Ne pas répéter un 404, une réponse non JSON ou une erreur de schéma.
Faire un petit appel réel puis sauvegarder les réponses pour pouvoir rejouer les essais sans réseau.
Si le réseau est indisponible, utiliser des réponses synthétiques construites dans les tests à partir du contrat ci-dessous ; les signaler comme telles.
Limiter cette collecte à 1–10 jeux ; ne pas envoyer un crawl de tout Steam depuis la salle.

**Objectif :** URLs et timestamps conservés ; une nouvelle exécution sans refresh ne fait pas d’appels HTTP.    
**Question :** pourquoi une réponse HTTP 200 peut-elle être inutilisable ?

### A3. Augmenter ou actualiser le corpus puis entraîner
Construire un snapshot à partir du CSV TP1 et des jeux collectés. Pour un appid déjà connu, remplacer la ligne ;
pour un nouveau, ajouter la ligne. Conserver une seule observation par appid avant le split du TP1.
Produire un rapport du nombre de jeux ajoutés et actualisés, les empreintes et les origines.
Appliquer les suites GX aux nouveaux jeux puis au snapshot complet, conformément à la partie Q.
Poursuivre vers le prétraitement et l'entraînement des deux tâches uniquement si tous les contrôles requis réussissent.
Le snapshot et le dossier de run sont nouveaux ; ne pas modifier le CSV historique.

**Objectif :** un cas « ajout » et un cas « actualisation », absence de doublon et deux modèles rechargeables.
Les appids 620, 400 et 550 sont absents du fichier initial fourni. Si les trois collectes aboutissent et passent vos contrôles,
attendre 94 951 lignes ; en utilisant ce snapshot comme base, une nouvelle collecte des mêmes jeux doit seulement les actualiser.  
**Question :** quel biais apparaît si deux observations du même jeu se retrouvent dans train et test ?

### A4. Incident d’acquisition
Simuler un 429 suivi d’un succès, trois 503, une tranche `0 - 0` et une réponse de fiche `success=false`.
Après un échec de la collecte demandée, ne lancer aucun entraînement partiel. Le cache peut contenir les
réponses déjà reçues, mais aucun nouveau modèle ne doit être publié. Vérifier les fichiers, pas seulement les logs.

**Objectif :** tests et empreintes des artefacts précédents inchangées.  
**Question :** pourquoi retenter une erreur de schéma serait-il différent de retenter un timeout ?

## Partie B — Recevoir les données

### B1. API d’entrée et stockage durable
Implémenter `POST /games` avec le contrat décrit plus bas. SQLite suffit pour ce TP.
L’événement doit être stocké avant de répondre ; une variable globale ou une liste en mémoire ne suffit pas.
Imposer l’unicité des `event_id` et `appid`, renvoyer les codes définis dans le contrat.
Le compteur porte sur les jeux valides distincts, et non sur les requêtes reçues.
Ajouter `/status` et `/batches/{id}` ; Swagger pourra être ouvert sur `http://127.0.0.1:8000/docs`.

**Objectif :** rejouer le même POST dix fois n’ajoute qu’un jeu ; un prix « gratuit » renvoie 422 sans changer le compteur.  
**Question :** que faire si le producteur ne reçoit pas la réponse alors que le serveur a déjà stocké le jeu ?

### B2. Réserver un lot et déclencher sans bloquer le POST
Dans **une transaction**, insérer le jeu, sélectionner les 500 jeux en attente et créer le job associé.
Réserver les identifiants du lot pour qu’un appel concurrent ne réutilise pas ces jeux.
Un worker local traite les jobs après le POST ; la requête HTTP ne doit pas attendre les forêts.
Conserver les états `PENDING → RUNNING → SUCCEEDED/FAILED` et une cause d’échec consultable.
Un job valide avec GX le CSV immuable des **500 jeux du lot uniquement**, avant le prétraitement.
Il entraîne ensuite les deux modèles seulement si les prérequis sont satisfaits ; sinon il passe en `FAILED`.

**Objectif :** zéro job à 499, un seul job à 500, un jeu en attente à 501 ; deux lots disjoints à 1 000.
Le 500e POST renvoie 202 avec un identifiant de lot ; cela signifie accepté, pas entraînement terminé.  
**Question :** pourquoi un test `if compteur == 500` hors transaction peut-il lancer deux entraînements ?

### B3. Faire jouer le rôle du producteur à un processus séparé
Le squelette fourni est volontairement non fonctionnel : compléter d'abord la création de l'application,
les routes, la validation, le stockage et le worker. Une fois `create_app` implémentée, lancer depuis la racine du projet :

```sh
uv run uvicorn api_trigger_passif.main:create_app --factory --host 127.0.0.1 --port 8000
```

Ne lancer qu'une instance de l'API/worker pour le socle, sans `--reload` ni plusieurs workers Uvicorn.
Dans un second terminal, utiliser le script fourni, qui prend **un seul argument : le nombre d'appels POST** :

```sh
uv run python simulateur_push.py 499
uv run python simulateur_push.py 1
uv run python simulateur_push.py 1
uv run python simulateur_push.py 499
```

Inspecter `/status` entre les commandes : 499, puis 500, puis 501, puis 1 000 jeux si tous les appels ont été acceptés.
Le script génère chaque jeu **aléatoirement à la volée**, sans CSV ni fixture. Il envoie les requêtes en rafale
avec au maximum huit requêtes en cours et une mémoire bornée. L'adresse est fixée dans `API_URL` en haut du script.
Le résultat affiche les nombres de réponses 202, 200, 4xx/5xx et erreurs réseau ; un code de sortie 1 signale des erreurs.
Un argument N signifie N tentatives, **pas N jeux acceptés** : aucun retry automatique ne masque les échecs.
Chaque lancement produit de nouveaux identifiants synthétiques très probablement distincts des précédents.
Le stockage de l'API reste responsable de détecter toute collision. Les labels sont artificiels et ne démontrent
aucune performance prédictive sur Steam. Quatre classes sont tirées au hasard ; cela ne garantit pas un équilibre exact.
Pour tester l'idempotence, renvoyer manuellement le même JSON (exemple ci-dessous) : relancer le simulateur crée de nouveaux jeux.

**Objectif :** deux processus distincts, états des lots, nombre exact de lignes des snapshots et fichiers des deux modèles.  
**Question :** où se trouve la décision de déclenchement, et qu’a réellement décidé le producteur externe ?

### B4. Pannes, reprise et bilan
Arrêter puis relancer le serveur à 499 jeux : le prochain jeu doit toujours déclencher le lot.
Tester un lot insuffisant pour la classification (une seule classe admissible selon les filtres) :
contrôle GX du lot en échec avant prétraitement, job FAILED, rapport conservé et aucun nouveau modèle.
Vérifier que l’API continue à accepter le lot suivant. Conserver les échecs pour diagnostic, sans boucle de retry infinie.
Un arrêt pendant RUNNING doit laisser un lot identifiable ; définir la stratégie de reprise.
Définir une reprise qui reconnaît un run déjà publié par son empreinte et évite un second entraînement inutile.

**Objectif :** historique durable, modèles précédents inchangés, pas de mélange de lots ni de perte du compteur.  
**Question :** pourquoi « exactement une fois » est-il une affirmation plus forte qu’un POST idempotent ?

## Livrables et réussite
- Modules Python du TP1 étendus, client HTTP, normalisation et rapport des sources.
- Adaptateur vers votre TP1, API de collecte, stockage durable, worker et simulateur exécuté.
- Tests couvrant schéma, panne HTTP, doublon, seuil, concurrence, restart et échec métier.
- Suites Great Expectations créées par SDK Python, contrats historique/nouvelles données documentés,
  rapports de validation et tests prouvant le blocage avant prétraitement dans les deux workflows.
- README de reprise, configurations, `pyproject.toml`, `uv.lock` et preuves des deux entraînements.
- Comparaison des workflows : initiateur, condition, latence, contrôle, risques, reprise ; expliquer aussi les limites des labels.

Les scores des deux workflows ne sont pas directement comparables : leurs corpus et leurs splits diffèrent.
Pour comparer des versions, il faudra ensuite définir un jeu d’évaluation commun, isolé de tous les jeux d’entraînement.
Ne pas promouvoir automatiquement un modèle parce que 500 événements ont été reçus.

## Indices graduels
1. Dessiner une frontière entre acquisition, validation, stockage et entraînement ; réutiliser le TP1 après cette frontière.
2. Un identifiant stable transforme un retry réseau en opération reconnaissable.
3. SQLite : contraintes UNIQUE et transaction `BEGIN IMMEDIATE` pour insertion + réservation.
4. Sauvegarder une table de jobs avant de répondre ; une tâche en mémoire seule disparaît au redémarrage.
5. Conserver une destination de sortie stable par lot permet de reconnaître un entraînement déjà terminé.

## Sources, mapping et contrat

## API retenues

Le site **SteamDB** ne documente pas d’API publique ouverte pour ce parcours. Sa FAQ oriente vers Steam
et refuse le scraping automatisé. Nous utilisons les sources ci-dessous, sans scraper SteamDB.
[Source : FAQ SteamDB](https://steamdb.info/faq/#does-steamdb-have-an-api)

| Besoin | Endpoint | Statut |
|---|---|---|
| Tranche de propriétaires estimés | `https://steamspy.com/api.php?request=appdetails&appid=620` | API tierce documentée par SteamSpy, sans clé pour cette requête |
| Métadonnées de la boutique | `https://store.steampowered.com/api/appdetails?appids=620&cc=us&l=english` | Endpoint public Steam Store constaté fonctionnel, contrat non garanti par une documentation officielle exhaustive |
| Résumé des avis | `https://store.steampowered.com/appreviews/620?json=1&language=all&purchase_type=all&filter=all&num_per_page=1` | Endpoint documenté par Steamworks |

[SteamSpy : documentation](https://steamspy.com/api.php) ·
[Steamworks : avis](https://partner.steamgames.com/doc/store/getreviews)

Trois jeux ont été vérifiés en ligne : Portal 2 (620), Portal (400), Left 4 Dead 2 (550).
Conserver dans votre cache seulement les champs utiles, sans texte des reviews ni profils d’utilisateurs.
Une réussite ponctuelle ne garantit ni la disponibilité future ni la complétude du catalogue.

## Débit et cache
SteamSpy annonce une actualisation quotidienne et un maximum d’une requête par seconde pour `appdetails`.
`request=all&page=0` permet de découvrir des identifiants (1 000 par page), mais est limité à une requête par minute.
Il n’est pas nécessaire pour le socle : partir de 1 à 10 appids choisis.
Ne pas faire lancer une collecte de tout le catalogue par chaque étudiant.

Votre client doit espacer tous les appels de 1,1 seconde, mettre en cache les réponses et utiliser un timeout de 20 secondes.
Cela constitue une précaution pédagogique, pas une garantie de quota pour Steam Store.
Au maximum trois tentatives sur erreur réseau, 429 ou 5xx ; respecter `Retry-After`.
Une pause demandée de plus de 60 secondes interrompt le parcours pour reprise ultérieure.
Les 4xx permanents, JSON invalides et erreurs métier ne déclenchent pas de retry aveugle.
Par défaut, le cache est relu ; `refresh` renouvelle Steam Store, mais respecte au minimum 24 h pour SteamSpy.
En salle, coordonner les appels et réutiliser vos réponses mises en cache pour ne pas multiplier le débit par classe.

## Reconstituer une ligne du TP1

| Colonne TP1 | Source et règle |
|---|---|
| appid | Identifiant demandé, doit correspondre à `steam_appid` et au `appid` SteamSpy |
| name | `data.name` |
| price | `price_overview.final / 100`, devise USD grâce à `cc=us` ; 0 si `is_free=true` ; null si prix absent |
| required_age | Entier issu de `required_age`, null si absent |
| dlc_count | Longueur de `data.dlc`, 0 si liste absente (convention à documenter) |
| achievements | `data.achievements.total`, null si absent |
| windows, mac, linux | Booléens de `data.platforms` |
| release_date | `data.release_date.date` convertie en date ISO ; exclure coming_soon et date non interprétable |
| genres | Liste des `description` ; sérialisée en texte de liste dans le CSV pour le module TP1 |
| num_reviews_total | `query_summary.total_reviews` |
| pct_pos_total | `100 × total_positive / total_reviews`, sur le résumé Steam avec les paramètres fixés ci-dessus |
| estimated_owners | `owners` SteamSpy : `5,000,000 .. 10,000,000` devient `5000000 - 10000000` |

Attention : `review_score` est une catégorie de score, **pas** un pourcentage.
`num_reviews` compte les avis retournés dans la page, **pas** le total du jeu.
Utiliser les compteurs du résumé, vérifier `total_positive + total_negative == total_reviews` et au moins 10 avis.
Ne pas remplacer une donnée manquante par une invention. Rejeter un identifiant caché SteamSpy `999999`, un DLC
ou une application non publiée. `estimated_owners` reste une estimation de propriétaires, pas les joueurs simultanés.

## Comparabilité avec le CSV historique
Le CSV du TP1 ne documente pas précisément la devise ni le périmètre de ses avis. Son `pct_pos_total`
est fourni tel quel, tandis que le TP2 le recalcule sur un périmètre explicite. Des écarts sont possibles.
Le flux actif démontre mécaniquement l’enrichissement/mise à jour ; il ne prouve pas une amélioration du modèle.
Conserver la provenance de chaque nouvelle ligne et celle du CSV initial. Avant une exploitation réelle, il faudrait
harmoniser les définitions de labels, la devise et la date d’observation, ou reconstruire un corpus homogène.
Ne jamais ajouter ces champs de provenance aux features par accident.

Les trois appids de démonstration (620, 400, 550) sont absents du CSV fourni : la collecte ajoute trois lignes,
de 94 948 à 94 951 jeux. Si ce nouveau snapshot devient la base d'une deuxième collecte des mêmes appids,
trois lignes sont actualisées et le nombre de jeux reste 94 951. Cela illustre les deux branches de l'upsert.
Il s'agit de jeux absents du dataset fourni, pas de jeux nouvellement sortis.

## Contrat de l’API passive
`POST /games`, JSON : un événement contenant `event_id`, `source`, `observed_at` (avec fuseau) et `game`.
Le JSON ci-dessous fournit un exemple complet. Le schéma de validation est à écrire par les étudiants.
Chaque événement contient **toutes les entrées et les deux labels** nécessaires : il s’agit donc de jeux
déjà observés, pas d’un mécanisme capable de labelliser un jeu sans avis ou sans estimation d’audience.

- 202 : jeu valide ajouté, avec `batch_id` si un lot vient d’être réservé.
- 200 : même événement ou même jeu identique déjà accepté ; aucun incrément.
- 409 : `event_id` réutilisé avec un autre contenu, ou appid déjà reçu avec d’autres valeurs.
- 422 : schéma ou valeurs métier invalides ; aucune écriture, aucun incrément.
- `GET /status` : jeux distincts acceptés, jeux en attente, seuil et états des lots.
- `GET /batches/{id}` : état d’un lot (`PENDING`, `RUNNING`, `SUCCEEDED`, `FAILED`), erreur ou sortie.

Le seuil est **500 appids distincts valides et non encore affectés**, puis 500 supplémentaires, etc.
499 ne lancent rien ; le 500e crée un job ; le 501e attend dans le lot suivant.
Le lot contient exactement ses 500 jeux. La base historique n’est pas ajoutée dans ce parcours.
Les doublons sont dédupliqués sur toute la campagne (le même `state_dir`), même après consommation du lot.
Les mises à jour successives d’un même appid sont volontairement hors du socle passif.

La validité d’une ligne ne garantit pas celle du lot : par exemple, 500 jeux d’une seule classe ne suffisent pas
à entraîner les deux modèles du TP1. Dans ce cas, conserver le lot en `FAILED`, garder les modèles précédents
et ne pas prétendre qu’un nouveau modèle a été produit.

## Exemple POST et règles de validation à implémenter

```json
{
  "event_id": "exemple-manuel-001",
  "source": "synthetic-course",
  "observed_at": "2026-10-03T12:00:00Z",
  "game": {
    "appid": 8000000000001,
    "name": "Jeu fictif de démonstration",
    "price": 19.99,
    "required_age": 12,
    "dlc_count": 2,
    "achievements": 45,
    "windows": true,
    "mac": false,
    "linux": true,
    "release_date": "2023-05-15",
    "genres": ["Action", "Indie"],
    "pct_pos_total": 84.5,
    "num_reviews_total": 200,
    "estimated_owners": "20000 - 50000"
  }
}
```

Utiliser cet exemple dans Swagger pour observer un premier envoi puis un doublon. Il s'agit d'un jeu fictif,
comme ceux du simulateur ; les grands appids synthétiques ne correspondent pas au catalogue Steam.

| Élément | Contrôle attendu |
|---|---|
| event_id | Chaîne non vide, identifiant d'événement stable lors d'un retry |
| source | `synthetic-course` pour le simulateur, `steam-store+steamspy` pour une collecte réelle ; ne pas mélanger silencieusement leurs origines |
| observed_at | Date/heure avec fuseau, conservée pour la traçabilité |
| appid | Entier positif, unique dans la campagne ; stockage entier 64 bits pour les identifiants du simulateur |
| name | Chaîne non vide |
| price | Nombre positif ou nul, ou null si indisponible ; refuser une chaîne comme « gratuit » |
| required_age, achievements | Entiers positifs ou nuls, ou null si indisponibles |
| dlc_count | Entier positif ou nul |
| windows, mac, linux | Vrais booléens, pas des chaînes |
| release_date | Date ISO valide |
| genres | Liste de chaînes ; convertir au format attendu par le prétraitement du TP1 lors de la création du snapshot |
| pct_pos_total | Nombre fini entre 0 et 100 |
| num_reviews_total | Entier au moins égal à 10 pour les jeux acceptés dans ce TP |
| estimated_owners | Deux bornes entières strictement croissantes séparées par ` - ` ; refuser `0 - 0` |

Les colonnes `positive` et `negative` du CSV initial servent à l'exploration ; elles ne sont pas requises
par les modèles. L'ingestion industrielle doit demander les features et les deux cibles utiles, et non
les colonnes de présentation du notebook. Aucun recalcul de label à partir des features n'est attendu.

## Squelette de l'API PUSH : fichiers fournis et pistes

```text
ENONCE.md
simulateur_push.py                # fourni entièrement ; bibliothèque standard Python
api_trigger_passif/
  __init__.py
  main.py                        # create_app : assembler routes et cycle de vie du worker
  validation.py                  # validate_event : contrat d'entrée à implémenter
  storage.py                     # store_event et get_status : persistance, unicité et réservation
  worker.py                      # process_pending_batches : traiter les jobs hors requête
  training_trigger.py            # trigger_training : appeler le projet TP1
```

Les fonctions du squelette lèvent `NotImplementedError`. Elles ne contiennent pas de solution et ne lancent
pas encore de serveur utilisable. Compléter les signatures si nécessaire et ajouter des fonctions auxiliaires.
Les étudiants produisent eux-mêmes configuration, tests et autres fichiers nécessaires dans leur projet.

- **main.py** : relier POST à validation puis stockage ; définir les GET de suivi ; démarrer et arrêter le worker.
- **validation.py** : un modèle Pydantic peut formaliser le tableau ci-dessus ; aucune écriture sur entrée invalide.
- **storage.py** : réfléchir à des tables d'événements/jeux et de lots, avec contraintes d'unicité et transaction.
  Le POST doit pouvoir savoir s'il a ajouté un jeu, reconnu un doublon ou réservé un lot.
- **worker.py** : distinguer réservation du job et entraînement ; conserver état et erreur après redémarrage.
- **training_trigger.py** : figer les 500 jeux, créer une configuration compatible avec le TP1 et appeler
  `main.py --config ...` dans le même environnement uv. Aucun code de forêt ni d'évaluation à recopier ici.

La partie PULL est à développer dans l'ingestion de votre projet TP1 : aucun nouveau client complet n'est fourni.
Ce document contient l'ensemble des consignes ; aucun autre document d'énoncé n'est requis.
