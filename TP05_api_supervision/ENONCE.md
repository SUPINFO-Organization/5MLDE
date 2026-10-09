# TP 05 — Servir les modèles, mesurer la capacité et superviser l'API

© SUPINFO — Auteur : Baptiste DAVID

Prérequis et installation : [guide commun Windows, macOS et Linux](../GUIDE_INSTALLATION.md). - 2026

**TP final**
Chapitre 6 : déploiement, dimensionnement et supervision.
Prérequis : code Python des TP1–TP4, deux modèles rechargeables depuis MLflow, Docker Compose, uv et bases SQL.

## Objectifs du TP

Mettre les deux modèles Steam à disposition d'utilisateurs, retrouver l'origine de chaque prédiction
et mesurer ce que votre poste peut réellement supporter. Conserver la régression du pourcentage
d'avis positifs et la classification des tranches de propriétaires estimés.

Les trois axes sont :

1. Une API FastAPI avec prédictions unitaires et par lots, feedbacks et traçabilité PostgreSQL.
2. Des scénarios Locust pour mesurer une capacité soutenable et l'effet du nombre de workers API.
3. Un dashboard Grafana connecté à PostgreSQL pour superviser usage, performances et retours.

Le code industriel des TPs précédents est votre base. Les entraînements restent orchestrés par
Prefect, validés avec GX et tracés dans MLflow. L'API d'inférence charge leurs modèles sans réentraîner
à chaque requête. Les cibles nécessaires à l'entraînement ne sont pas exigées pour prédire.

Sont fournis : cet énoncé, le Compose commun enrichi, `init-db.sql` et le provisioning de la source
PostgreSQL de Grafana. **L'API, les scénarios Locust, les requêtes du dashboard et le dashboard sont
à produire par les étudiants.** Aucun notebook ni corrigé n'est fourni.

## Préparer la stack et lire le schéma

Le Grafana des TPs précédents est réutilisé ; une instance PostgreSQL **18.6** est ajoutée.
Depuis le dossier du Compose :

```sh
docker compose config --quiet
docker compose up -d --wait --wait-timeout 180
docker compose ps
docker compose exec -T postgres psql -U postgres -d steam_api -c "\dt tracing.*"
```

Au premier démarrage sur un volume vide, PostgreSQL exécute automatiquement le script fourni.
Un redémarrage ne rejoue pas les scripts d'initialisation. Pour réappliquer ce même schéma sans
effacer les données, ou renouveler les mots de passe applicatifs après modification du `.env` :

```sh
docker compose exec -T postgres psql -U postgres -d steam_api -f /docker-entrypoint-initdb.d/010-tracing.sql
```

Ce script est réexécutable sur sa propre version ; il ne migre pas une structure modifiée à la main.
Ne pas supprimer les volumes pour résoudre une erreur de configuration : ils contiennent aussi les
modèles MLflow, l'historique Prefect et les dashboards.

| Accès local | Valeur par défaut |
|---|---|
| PostgreSQL | `127.0.0.1:5432`, base `steam_api`, schéma `tracing` |
| Compte API | `api_writer`, mot de passe `5mlde-local-api`, droits SELECT et INSERT |
| Compte Grafana | `grafana_reader`, mot de passe `5mlde-local-grafana`, lecture seule |
| Grafana | `http://localhost:3000`, identifiants du Compose existant |
| Source Grafana fournie | `Steam API - PostgreSQL`, UID `steam-api-postgres` |
| Nouvelle API d'inférence | `127.0.0.1:8001`, pour conserver le port 8000 de la collecte PUSH |

Les mots de passe de démonstration sont configurables dans `.env.example`. Le `.env` du Compose
n'est pas automatiquement lu par votre application. Définir ses paramètres PostgreSQL dans le
terminal ou une configuration locale non versionnée, et conserver `MLFLOW_TRACKING_URI`.
Depuis Grafana, l'hôte est `postgres:5432`, pas `localhost:5432`.

Ajouter les dépendances au projet uv existant, puis versionner le verrou :

```sh
uv add fastapi uvicorn "psycopg[binary,pool]" "locust==2.46.6"
```

Utiliser le compte applicatif, jamais le superutilisateur PostgreSQL dans l'API.
La pile fonctionne localement ; aucune authentification publique ni exposition Internet n'est demandée.

## Axe 1 — API, feedbacks et traçabilité

### A1. Charger les modèles une fois par worker

Créer un package d'inférence distinct de l'API PUSH du TP2, par exemple `api_prediction`, qui expose
un objet FastAPI `app`. Réutiliser les transformations et modèles sérialisés ; ne pas réécrire les
features différemment pour l'inférence. Garder `main.py` pour le workflow d'entraînement.

Préparer un manifeste de service contenant les **deux noms et numéros de version MLflow précis**.
Si vous partez de l'alias `champion`, le résoudre une seule fois pour constituer ce manifeste avant
de démarrer tous les workers. Enregistrer également les URI et runs d'origine. Un alias mutable
ne suffit pas à identifier ce qui a réellement prédit.

Charger ce couple au démarrage de chaque worker, dans le cycle de vie de l'application, puis le
réutiliser en mémoire. Créer également un pool PostgreSQL par processus. Un échec de chargement ou
une incompatibilité de contrat doit empêcher ce worker de se déclarer prêt.
[Référence : cycle de vie FastAPI](https://fastapi.tiangolo.com/advanced/events/).

Le socle utilise une version figée jusqu'au redémarrage. Après un changement du manifeste,
redémarrer tous les workers et vérifier leur identité : changer l'alias dans MLflow ne met pas à
jour les objets déjà chargés. Un retour arrière réutilise le manifeste précédent.
Si aucun modèle réel n'est qualifié au TP3, utiliser un couple explicitement `demo` pour l'exercice
technique et conserver cette distinction dans les noms et le rapport.

**Objectif :** deux requêtes successives réutilisent les modèles ; les versions réelles sont visibles.

### A2. Construire les contrats HTTP

Implémenter des endpoints différents pour les deux modes :

| Endpoint | Entrée | Sortie nominale |
|---|---|---|
| `POST /predict` | Un objet `game` contenant les métadonnées nécessaires au pipeline | Un `request_id`, les deux résultats, chacun avec `prediction_id` et identité du modèle |
| `POST /predict/batch` | Une liste `games` de 1 à 100 objets | Un `request_id`, les résultats ordonnés avec `item_index` et deux identifiants de prédiction par jeu |
| `POST /feedback` | `feedback_id`, `prediction_id`, avis et/ou label observé | Identifiant du feedback enregistré et statut |
| `GET /health/live` | Aucune | Processus vivant |
| `GET /health/ready` | Aucune | Modèles chargés et connexion PostgreSQL disponible, sinon 503 |

Décrire les objets et exemples dans OpenAPI. Les entrées utilisent le contrat d'inférence du TP1 :
prix, âge requis, DLC, succès, plateformes, genres et date de sortie. `appid` sert à la traçabilité,
pas de feature. Ne pas demander `pct_pos_total` ni `estimated_owners` pour une prédiction.
Valider les types, bornes et champs requis ; conserver les nulls et genres inconnus autorisés par
le pipeline. Ne pas employer telle quelle la suite GX d'entraînement qui exige les cibles.

Pour le lot, adopter une réponse **tout ou rien** : une entrée invalide rejette le lot avant le calcul,
et aucune prédiction partielle n'est enregistrée. Quand le lot est valide, appeler les pipelines sur
un DataFrame de N lignes ; comparer avec N appels unitaires sur les mêmes jeux.

Contrat d'erreur minimal : 422 pour une entrée invalide, dont une liste vide ou de plus de 100 jeux ;
404 pour un feedback visant une prédiction absente ; 409 pour un conflit d'identité de feedback ;
503 pour une indisponibilité de modèle ou de stockage. Une erreur inattendue donne 500 avec un
code public court et un diagnostic local, sans exposer les secrets ou une trace Python au client.
La réponse d'erreur porte un `request_id`. Les requêtes valides de prédiction renvoient 200.

**Objectif :** tests de contrat, cohérence unitaire/lot et refus d'un lot partiellement invalide.

### A3. Écrire les traces dans les tables fournies

Le script prépare les contraintes, index et permissions. Vous n'avez pas à créer les tables :
vous devez savoir où écrire et comment retrouver une réponse.

| Table | Une ligne représente | Champs et liens à exploiter |
|---|---|---|
| `tracing.model_versions` | Une version exacte d'un modèle | `model_id`, tâche, serveur MLflow, nom, version, URI et run MLflow |
| `tracing.api_requests` | Une tentative HTTP sur l'un des trois endpoints métier | `request_id`, date, statut, nombre de jeux, durées, worker, révision API et campagne |
| `tracing.predictions` | Un résultat pour un jeu et une tâche | `prediction_id`, requête, position du jeu, features utiles, modèle et valeur prédite |
| `tracing.feedbacks` | Un retour immuable sur une prédiction | `feedback_id`, prédiction, requête d'origine du feedback, avis et/ou label observé |

Pour une requête valide de N jeux : **1 ligne de requête et 2N lignes de prédiction**. Une requête
en erreur possède sa trace mais aucune prédiction. Les endpoints de santé ne sont pas enregistrés
dans ces tables afin de ne pas fausser les statistiques métier.

Générer les UUID dans l'application. `instance_id` change à chaque démarrage de worker ; `worker_pid`
seul ne permet pas de distinguer tous les redémarrages. `campaign_id` vaut `manual` par défaut ;
les tests de charge transmettront un identifiant via `X-Test-Campaign`, de longueur bornée.
Conserver `api_revision` et la même configuration de service pendant une campagne.

Plusieurs workers peuvent découvrir la même version MLflow : utiliser l'unicité
`(tracking_uri, registered_name, version)` pour retrouver son `model_id` après un conflit d'insertion.
Vérifier que les autres métadonnées correspondent ; ne pas réécrire l'historique pour suivre un alias.

Une transaction doit contenir la trace de la requête réussie et toutes ses prédictions, ou la trace
du POST feedback et son nouveau feedback. **Répondre en succès seulement après commit.** Le traitement
doit contrôler les invariants inter-tables : deux tâches par jeu valide, indices cohérents avec le
lot, endpoint approprié. Les clés étrangères ne prouvent pas à elles seules ces invariants.

Tracer aussi les 422 produits par FastAPI et les erreurs des handlers. Choisir un point de
journalisation commun afin de ne pas compter deux fois une erreur. Si l'insertion échoue,
annuler la transaction puis renvoyer 503. Si possible, écrire une trace d'erreur dans une nouvelle
transaction ; si PostgreSQL est indisponible, conserver un journal local structuré avec l'identifiant.
Le dashboard SQL aura alors un trou : les erreurs Locust restent la référence externe.
Le socle n'impose pas de file de reprise des traces perdues ; documenter cette limite.

Les deux durées ont une définition précise :

- `processing_duration_ms` : horloge monotone, du début du traitement HTTP jusqu'avant la transaction
  finale de traçabilité ; inclut validation et inférence, exclut cette transaction, le commit et le réseau.
- `inference_duration_ms` : temps cumulé des deux appels `predict` pour toute la requête ; null si
  aucune inférence n'a eu lieu. Ne pas inventer un percentile par jeu en divisant ce temps par N.

Utiliser des dates UTC pour l'axe temporel ; ne pas calculer une durée en soustrayant deux horloges
murales. La latence Locust inclura notamment l'attente du client et l'écriture PostgreSQL : elle sera
analysée séparément. Enregistrer seulement les features utiles, sans IP, identité personnelle ou
corps d'erreur complet. PostgreSQL n'est pas ici un moteur de traces distribuées.

Le pool est borné, fermé à l'arrêt du worker et adapté aux appels sync/async retenus. Quatre workers
avec un pool de cinq connexions représentent jusqu'à vingt connexions API, auxquelles s'ajoutent
Grafana et l'administration. Utiliser des requêtes paramétrées.
[Référence : pools psycopg](https://www.psycopg.org/psycopg3/docs/advanced/pool.html).

**Objectif :** reconstituer une réponse uniquement à partir de son identifiant, puis simuler un échec
de transaction pour démontrer l'absence de prédictions partielles ou de faux succès HTTP.

### A4. Recueillir et interpréter les feedbacks

Un retour peut être subjectif (`useful`, booléen) et/ou fournir une observation : `observed_pct`
pour la régression, `observed_owners` pour la classification. Le client ne choisit pas le modèle :
le serveur le retrouve par la prédiction, et déduit également la tâche associée.
Une observation doit inclure `observed_at` et `label_source`. Sans observation, ces deux champs
restent absents. Vérifier plages, tranche et cohérence avec la tâche.

Le socle accepte **un feedback immuable par prédiction**. Le client génère un `feedback_id` stable
pour ses retries. Premier envoi : 201 ; même identifiant et contenu identique : 200 sans nouvelle
ligne de feedback ; identifiant réutilisé avec un autre contenu, ou deuxième feedback différent pour
la même prédiction : 409. Chaque tentative reste une nouvelle ligne HTTP. Le `request_id` de la
ligne feedback reste celui de sa création, même si le client la rejoue.

Traiter les conflits concurrents via les contraintes SQL, pas avec un simple « vérifier puis insérer ».
Un retry après perte de réponse ne doit pas faire compter deux avis. Un feedback négatif n'entraîne
ni réentraînement ni changement automatique d'alias dans ce TP.

Calculer des métriques seulement sur les prédictions possédant un label observé exploitable.
Un pouce positif n'est pas une vérité terrain. Pour les avis Steam, vérifier le périmètre et la date
de l'observation avant de comparer le pourcentage ; pour les tranches, conserver la même définition.
Les feedbacks sont une population auto-sélectionnée : indiquer leur nombre et leur couverture.
Marquer les retours artificiels `label_source=loadtest` ou `synthetic-course` pour les exclure des
indicateurs de qualité réelle ; ils servent uniquement à tester le mécanisme.

**Objectif :** retour subjectif, label observé, replay idempotent, conflit et rejet d'un identifiant inconnu.

## Axe 2 — Mesurer une capacité soutenable avec Locust

### B1. Construire des scénarios qui vérifient les réponses

Écrire `locustfile.py` dans votre projet, en utilisant `HttpUser`, des tâches et un temps d'attente
explicite. Définir des scénarios séparés : unitaire, lot de taille fixe (par exemple 20), puis un
mélange réaliste avec quelques feedbacks après réception d'identifiants de prédiction.

Les données de charge sont construites à l'avance à partir de métadonnées valides. Ne pas appeler
les API Steam pendant les tirs. Vérifier le statut, le nombre de résultats, les identifiants et les
valeurs retournées avec `catch_response` : un 200 dont le corps est invalide compte comme un échec.
Utiliser des noms de statistiques stables par endpoint, jamais un nom contenant un UUID.
[Référence : scénarios Locust](https://docs.locust.io/en/stable/writing-a-locustfile.html).

Les tests de réponses 4xx attendues constituent une campagne fonctionnelle séparée : ils ne doivent
pas masquer les erreurs de la campagne nominale de capacité. Générer des feedbacks artificiels avec
une provenance explicite et ne pas en créer plusieurs pour la même prédiction.

**Objectif :** un tir court à faible charge réussit, et une réponse volontairement incorrecte est
comptée en échec par Locust. PostgreSQL contient les traces de cette campagne.

### B2. Comparer 1, 2 puis 4 workers FastAPI

Si votre package suit le nom proposé, lancer successivement :

```sh
uv run --locked uvicorn api_prediction.main:app --host 127.0.0.1 --port 8001 --workers 1
uv run --locked uvicorn api_prediction.main:app --host 127.0.0.1 --port 8001 --workers 2
uv run --locked uvicorn api_prediction.main:app --host 127.0.0.1 --port 8001 --workers 4
```

Arrêter complètement le serveur entre les commandes. Ne pas utiliser `--reload`. Vérifier les
versions chargées, le nombre de processus et la disponibilité avant chaque tir. Chaque worker
possède ses modèles et son pool : mesurer aussi le coût mémoire.
[Référence : workers Uvicorn/FastAPI](https://fastapi.tiangolo.com/deployment/server-workers/).

Ne pas bloquer la boucle async avec un calcul sklearn ou un accès SQL synchrone sans stratégie
adaptée : choisir des handlers synchrones ou déporter explicitement le calcul bloquant.
Fixer et consigner le parallélisme interne des modèles, des bibliothèques numériques et des pools.
Multiplier des workers dont chaque forêt utilise tous les cœurs peut réduire le débit.

Pour chaque configuration, appliquer le même protocole :

1. Fixer le couple de versions MLflow, le dataset client, la taille des lots et la politique d'attente.
2. Faire une chauffe séparée ; donner à chaque tir mesuré un nouvel identifiant de campagne.
3. Augmenter progressivement la concurrence, par exemple 5, 10, 20 puis 40 utilisateurs ; affiner
   autour du premier palier qui dégrade les critères. Garder un temps de stabilisation et une durée identiques.
4. Répéter au moins trois fois le palier candidat et celui situé juste au-delà. Si le temps manque,
   signaler les mesures exploratoires qui n'ont pas encore cette répétition.
5. Conserver CSV Locust, erreurs, paramètres, versions, CPU/RAM du poste et observations PostgreSQL.

Exemple de commande, après création du scénario et du dossier `resultats/` :

```sh
uv run --locked locust -f locustfile.py --host http://127.0.0.1:8001 --headless -u 20 -r 2 -t 3m --csv resultats/w1-u20-r1
```

Le nom d'export n'est pas automatiquement envoyé à l'API : votre scénario lit une configuration
de campagne et transmet `X-Test-Campaign`. Pour l'interface interactive, `uv run --locked locust
-f locustfile.py --host http://127.0.0.1:8001` utilise par défaut le port 8089.
[Référence : tirs sans interface](https://docs.locust.io/en/stable/running-without-web-ui.html).

**Objectif :** matrice « workers × concurrence × scénario » avec débit, p50/p95/p99, erreurs et ressources.

### B3. Définir ce que signifie « capacité maximale »

Définir **avant** les mesures un objectif de service par endpoint. Exemple pédagogique à adapter :
p95 client inférieur à 500 ms et moins de 1 % d'échecs sur un palier stable ; prévoir un objectif
distinct pour les lots. Ce sont des critères d'expérience, pas des performances promises.

La capacité retenue est le plus grand débit **soutenu observé** respectant ces critères sur votre
protocole, pas le plus grand pic de RPS. Si aucun palier ne sature le système, présenter une borne
inférieure plutôt qu'une limite inventée. Les utilisateurs virtuels ne sont pas des requêtes/seconde :
Locust attend les réponses et votre temps d'attente influence la charge réellement injectée.

Rapporter à la fois requêtes/s et jeux/s ; une requête de 20 jeux produit 40 résultats de modèle.
Comparer unitaire et lot à volume de jeux expliqué. Ne pas attribuer au nombre de workers un gain
obtenu en changeant aussi les modèles, la base, le pool ou la taille des lots.

Sur un poste unique, Locust, Docker, PostgreSQL, Grafana et l'API se partagent CPU et RAM. Surveiller
le générateur et ses avertissements CPU ; s'il sature, déplacer la charge sur une machine autorisée
ou expliquer cette limite. Les workers Locust génèrent la charge, les workers Uvicorn servent les
requêtes : leurs nombres sont deux variables différentes.
[Référence : génération distribuée Locust](https://docs.locust.io/en/stable/running-distributed.html).

Mettre en pause les entraînements, plannings Prefect et autres charges parasites pendant les tirs.
Garder la traçabilité PostgreSQL activée : c'est le service complet que vous mesurez. Fixer aussi la
fréquence de rafraîchissement Grafana, ou le fermer pendant toute la série puis analyser après coup.

**Objectif :** conclusion argumentée, point de saturation probable et limites de généralisation.

## Axe 3 — Construire le dashboard Grafana

La source PostgreSQL est provisionnée, mais **le dashboard reste à créer** dans Grafana.
Vérifier sa connexion, puis construire les requêtes dans Explore avant les panneaux. Le compte
`grafana_reader` ne doit pouvoir ni insérer ni supprimer les traces. Son pool est limité à cinq
connexions et ses requêtes à dix secondes.
[Référence : source PostgreSQL](https://grafana.com/docs/grafana/latest/datasources/postgres/configure/).

Créer un dashboard « Steam API — usage et performances » comprenant :

| Panneau | Mesure attendue et point d'attention |
|---|---|
| Usage | Nombre de requêtes, requêtes/s et jeux traités/s ; distinguer succès et tentatives |
| Erreurs | Taux de 4xx et 5xx par endpoint, codes d'erreur et nombre absolu |
| Durées | p50/p95/p99 de `processing_duration_ms` par endpoint, série distincte pour l'inférence |
| Lots | Taille des lots et débit de jeux ; éviter une moyenne confondant unitaire et batch |
| Modèles servis | Volume de prédictions par tâche, nom et numéro exact de version |
| Workers | Activité par `instance_id`/PID ; ce compteur n'est pas une mesure CPU |
| Feedbacks | Nombre, proportion d'avis favorables et couverture des prédictions avec retour |
| Qualité observée | MAE de régression et taux de classification correcte sur labels observés comparables, avec effectifs |

Ajouter les filtres temporels, de campagne et d'endpoint ; compléter les panneaux de modèle avec
des filtres de tâche/version. Utiliser les macros PostgreSQL de Grafana, dont `$__timeFilter`, et
des requêtes adaptées à la fenêtre temporelle ; tester les valeurs de filtres plutôt que concaténer
naïvement du SQL. Choisir des unités explicites : millisecondes, pourcentage, requêtes/s ou jeux/s.
[Référence : éditeur SQL et macros](https://grafana.com/docs/grafana/latest/datasources/postgres/query-editor/).

Calculer les percentiles sur les observations de requêtes, jamais en moyennant des percentiles
de workers. Une jointure requêtes→prédictions multiplie les lignes par 2N : elle ne doit pas multiplier
le débit HTTP, les erreurs ou le poids d'une durée. Pour ces métriques, partir de `api_requests`.
Pour les modèles et feedbacks, joindre les tables en respectant leur granularité.

Pour la couverture et la qualité, choisir une cohorte de prédictions par date de prédiction,
puis chercher leurs retours éventuellement plus tardifs. Afficher séparément le volume de retours
reçus pendant la fenêtre. Exclure les labels artificiels des scores réels, distinguer avis subjectifs
et observations, et afficher « pas de données » quand le dénominateur est nul.

Une absence de ligne PostgreSQL ne prouve pas une absence d'erreur : les pannes de cette base et
les requêtes qui n'atteignent pas l'API ne sont pas visibles ici. Comparer les totaux avec Locust
sur une campagne isolée et expliquer les écarts. Le dashboard affiche une durée de traitement,
pas la latence réseau client ni la CPU réelle ; ces mesures viennent d'autres observations.

Rafraîchir toutes les 10–30 secondes pour commencer et mesurer le coût des requêtes. Aucune
installation de Prometheus n'est nécessaire pour ce socle SQL.

**Objectif :** dashboard exporté en JSON par vos soins, requêtes versionnées, filtres fonctionnels et
vérification manuelle des totaux sur une petite campagne connue. Après redémarrage de Grafana,
retrouver le dashboard dans le volume persistant.

## Audit final et livrables

Faire démontrer le parcours complet à un autre binôme : prédire un jeu, envoyer un lot, retrouver
les versions exactes en base, déposer un retour, lancer une petite charge puis observer le dashboard.

Tests incontournables :

- Unitaire et lot donnent les mêmes résultats pour les mêmes modèles et entrées.
- Lot invalide ou panne d'insertion : aucune prédiction partielle et aucun faux succès.
- Feedback rejoué ou concurrent : aucune duplication et réponse conforme au contrat.
- Changement de manifeste : nouveaux workers sur les bonnes versions, anciennes traces inchangées.
- PostgreSQL arrêté : API non prête, requête en erreur explicite et diagnostic local ; reprise après redémarrage.
- Modèle refusé par le TP3 : aucune sélection implicite pour la production ; démonstration identifiée si nécessaire.

Livrer le code API et ses tests, contrats OpenAPI, manifeste des modèles, paramètres de pools et
workers, scénarios Locust, résultats et analyse de capacité, export du dashboard et rapport bref.
Les mots de passe et données de test volumineuses ne sont pas à committer. Les tables sont fournies,
mais vous devez expliquer leurs clés, leurs cardinalités et les transactions de votre API.

Une capacité modestement mesurée et correctement expliquée vaut mieux qu'un chiffre élevé obtenu
en désactivant les traces ou en ignorant les erreurs. Aucune infrastructure de production n'est
promise à partir d'un poste de cours.

PostgreSQL 18.6 est la version stable retenue
pour l'image officielle ; la pile MLflow/Prefect/Grafana conserve les versions déjà fixées dans
le Compose. [Image PostgreSQL](https://hub.docker.com/_/postgres) ·
[Version PostgreSQL](https://www.postgresql.org/docs/release/18.6/).
