# TP 04 — Orchestrer les workflows Python avec Prefect

© SUPINFO — Auteur : Baptiste DAVID

Prérequis et installation : [guide commun Windows, macOS et Linux](../GUIDE_INSTALLATION.md). - 2026

Ce TP correspond au **chapitre 5 : industrialisation des pipelines ML**.
Prérequis : quatre modules du TP1 fonctionnels, workflows PULL/PUSH du TP2, suivi et registre MLflow du TP3.

## Objectifs du TP

Votre pipeline entraîne et trace ses modèles. Cependant, lorsqu'une acquisition échoue ou qu'un
entraînement reste bloqué, il faut encore explorer plusieurs journaux pour comprendre la situation.
Vous allez intégrer **le SDK Python de Prefect** à ce code pour observer chaque étape, maîtriser
les reprises et déclencher une exécution sans lancer manuellement toute la chaîne.

À la fin du TP, vous devez pouvoir :

1. Transformer l'orchestration existante en flow, et les quatre fonctions mères en tâches suivies.
2. Diagnostiquer une exécution à partir de ses états, dépendances, logs et durées.
3. Retenter une erreur temporaire sans masquer une donnée invalide ni dupliquer une publication MLflow.
4. Exécuter un déploiement local planifié, maîtriser un cache et notifier un incident dans Teams.

Reprendre **votre propre projet uv**, ses modèles, ses tests et le `compose.yml` commun.
Ce document est le seul support fourni : vous écrivez les adaptations Python, sans notebook ni corrigé.

## Comprendre les objets que vous allez observer

| Objet | Rôle dans ce TP |
|---|---|
| Flow | Fonction Python qui orchestre le pipeline complet |
| Flow run | Une exécution de ce pipeline avec ses paramètres et son état |
| Task | Fonction Python représentant une étape observable et éventuellement rejouable |
| Task run | Une exécution d'une tâche ; son historique peut comporter des retries |
| Job PUSH du TP2 | Lot métier durable de 500 jeux, conservé dans votre base de collecte |
| Deployment | Définition permettant de déclencher un flow avec des paramètres, éventuellement un planning |

Dans l'interface Prefect, les « jobs » des fonctions mères seront donc des **task runs**.
Le job métier du TP2 garde son identité : il ne se confond ni avec une task run ni avec un run MLflow.
Un serveur Prefect observe et coordonne les exécutions ; il n'exécute pas à lui seul votre code Python.
[Références : flows](https://docs.prefect.io/v3/concepts/flows) et
[tasks](https://docs.prefect.io/v3/concepts/tasks).

## 1 — Connecter le SDK au serveur commun

Depuis le dossier contenant le Compose :

```sh
docker compose config --quiet
docker compose up -d --wait --wait-timeout 180 prefect mlflow
docker compose ps
```

Ouvrir [Prefect](http://localhost:4200) et [MLflow](http://localhost:5000).
Dans le projet Python des TPs précédents, aligner le SDK sur le serveur **Prefect 3.8.7** du Compose :

```sh
uv add "prefect==3.8.7"
uv run --locked python -c "import prefect; print(prefect.__version__)"
```

Conserver le client MLflow du TP3 et versionner le nouveau `uv.lock`.
Configurer chaque terminal exécutant votre code, notamment celui du worker PUSH :

```powershell
# PowerShell
$env:PREFECT_API_URL = "http://localhost:4200/api"
$env:MLFLOW_TRACKING_URI = "http://localhost:5000"
$env:MLFLOW_REGISTRY_URI = "http://localhost:5000"
```

```sh
# Linux/macOS
export PREFECT_API_URL=http://localhost:4200/api
export MLFLOW_TRACKING_URI=http://localhost:5000
export MLFLOW_REGISTRY_URI=http://localhost:5000
```

Adapter les ports personnalisés. L'URL Prefect doit inclure `/api`. Redémarrer les processus lancés
avant la définition des variables. Le `.env` du Compose n'exporte pas ces variables dans le shell.
Le client Python tourne sur le poste : ne pas lui donner le nom DNS `prefect` réservé au réseau Docker.
Ne pas démarrer de serveur éphémère à la place du serveur commun.

**Objectif :** versions et URL consignées dans votre rapport ; les deux interfaces sont accessibles.

## 2 — Rendre visibles les quatre étapes

**Problème :** une seule commande exécute toute la chaîne, mais on ne voit pas ses étapes dans Prefect.
Utiliser les décorateurs `flow` et `task` du SDK, en conservant les responsabilités du TP1 :

| Fichier existant | Fonction mère | Objet Prefect attendu |
|---|---|---|
| `main.py` | `main(config_path)` | Flow du pipeline |
| `src/ingestion.py` | `load_data` | Task d'ingestion |
| `src/preprocessing.py` | `preprocess_data` | Task de prétraitement |
| `src/training.py` | `train_models` | Task d'entraînement des deux modèles |
| `src/evaluation.py` | `evaluate_models` | Task d'évaluation et de publication du TP3 |

Donner des noms lisibles aux flows et tâches. **Le corps de `main.py` continue uniquement à chaîner
les quatre appels** ; le décorateur et ses options portent l'orchestration, les helpers techniques
restent dans leurs modules. Ne pas recopier le code d'entraînement dans un nouveau pipeline parallèle.
Pour une méthode de classe, garder la même responsabilité et éviter de transmettre à Prefect une
instance contenant des connexions ouvertes ou des états globaux non maîtrisés.

Commencer par des appels directs aux tâches, donc une exécution séquentielle. Transmettre leurs
résultats à l'étape suivante pour exprimer les dépendances. Ne pas transformer chaque petite
fonction utilitaire en tâche : choisir une granularité qui aide à diagnostiquer ou à reprendre.

Pour ce premier passage, définir explicitement **zéro retry**, **`cache_policy=NO_CACHE`** et
**`persist_result=False`** sur les quatre tâches. Importer `NO_CACHE` depuis `prefect.cache_policies`.
Cela permet d'observer les appels métier et les effets MLflow sans réutilisation implicite.
Le cache sera introduit sur un calcul isolé dans la partie 7.

Relancer la commande conservée depuis le TP1 :

```sh
uv run --locked python main.py --config config.json
```

Dans le socle, ce processus Python exécute le flow : aucun worker Prefect ou work pool supplémentaire
n'est nécessaire. Le conteneur Prefect reçoit les informations de suivi.

**Objectif :** un flow run et quatre task runs identifiables, avec ordre, dates, durées et états.
Les deux modèles restent produits et rechargeables depuis MLflow.
**Question :** quelle information manque si seul `main` est instrumenté ?

## 3 — Relier les logs, Prefect et MLflow

Ajouter des logs utiles avec `get_run_logger`, appelé **dans un contexte d'exécution Prefect**.
Journaliser le début d'une étape, les volumes utiles, les filtres, les références des sorties et
une cause d'échec compréhensible. `log_prints=True` permet de récupérer des `print` existants, mais
des logs contextualisés restent attendus. Ne pas imprimer tout un DataFrame ou un modèle sérialisé.
[Référence : journalisation](https://docs.prefect.io/v3/how-to-guides/workflows/add-logging).

Définir la répartition des informations :

| Prefect : suivi opérationnel | MLflow : suivi des modèles |
|---|---|
| Étape en cours, état, tentative et durée | Données utilisées, code, configuration et hyperparamètres |
| Erreur, attente avant retry, lancement planifié | Métriques, pipelines rechargeables, versions et qualification |
| Identifiants de flow/task et liens vers les résultats | Identifiant du flow à l'origine de l'entraînement |

Conserver une correspondance `batch_id` ou identifiant PULL → `flow_run_id` → `mlflow_run_id`.
Dans MLflow, ajouter l'identifiant du flow comme tag de traçabilité ; dans les logs ou le résultat du
flow, fournir le run MLflow et les versions publiées. Utiliser les informations d'exécution du SDK,
notamment `prefect.runtime.flow_run.id` et `prefect.runtime.task_run.id`, dans le bon contexte.
[Référence : informations runtime](https://docs.prefect.io/v3/how-to-guides/workflows/access-runtime-info).

Le TP3 utilise un run MLflow par tentative de pipeline. Un retry interne de tâche appartient au
même flow run et conserve ce run MLflow. Un nouvel entraînement intentionnel crée un nouveau run ;
une reprise de publication retrouve les identifiants déjà enregistrés. Transmettre le `run_id`
explicitement : ne pas dépendre uniquement du run MLflow actif dans un thread ou processus.

Un flow techniquement `Completed` peut avoir produit un modèle `rejected` selon la politique du TP3.
Ce refus métier n'est pas une panne de l'orchestrateur. Inversement, un calcul terminé avec une
publication MLflow en échec ne doit pas être annoncé comme un pipeline entièrement réussi.

**Objectif :** partir d'un lot PUSH pour retrouver les logs d'une étape puis les deux modèles dans MLflow.
**Question :** pourquoi le tag MLflow `production-ready` ne correspond-il pas à un état Prefect ?

## 4 — Reprendre uniquement ce qui peut réussir

**Incident :** une API répond temporairement 503 ; un autre appel renvoie un JSON métier invalide.
Écrire votre politique avant de configurer les retries :

| Situation | Décision à justifier et à tester |
|---|---|
| Timeout réseau, 429 ou 503 temporaire | Retry borné avec délai, si la requête peut être rejouée |
| Prix non numérique, schéma invalide, classe impossible | Échec explicite sans retry automatique |
| Échec après création d'une version MLflow | Vérification des effets déjà produits avant toute reprise |
| Traitement trop long | Limite temporelle et diagnostic de l'étape concernée |

Configurer `retries`, `retry_delay_seconds` et, lorsque nécessaire, `retry_condition_fn` sur la
tâche concernée. **Deux retries donnent au maximum trois tentatives**. Garder zéro retry global
sur le flow pour éviter de rejouer toute la chaîne dans ce premier parcours.
[Référence : retries conditionnels](https://docs.prefect.io/v3/how-to-guides/workflows/retries).

Le client HTTP du TP2 a déjà ses reprises : choisir une seule couche responsable de ces retries,
ou calculer et vérifier un budget total. Ne pas multiplier silencieusement les appels en combinant
trois tentatives HTTP avec trois tentatives de task. Respecter toujours les quotas et `Retry-After`.
Si toute l'ingestion est rejouée, conserver la collecte idempotente et le même run MLflow.
Vous pouvez isoler l'appel réseau dans une sous-tâche, tout en gardant la tâche mère visible.

Configurer un timeout HTTP réel sur le client, puis une limite `timeout_seconds` adaptée à la tâche.
Un timeout Prefect n'annule pas les effets déjà produits ; un appel bloquant ou un thread peut
nécessiter son propre mécanisme d'interruption. Tester avec une panne contrôlée, sans provoquer
de surcharge sur les API publiques.

Faire évoluer la fermeture du run MLflow du TP3 : ne pas le terminer définitivement au premier
échec temporaire si une task va être réessayée. Il reste ouvert pendant les retries, puis se ferme
à la réussite ou à l'échec terminal du pipeline. Les hooks d'état du flow peuvent déléguer cette
finalisation à un helper, en gardant le corps de `main` minimal. Ils ne garantissent pas une
réconciliation après une coupure brutale du processus ou du serveur.
[Référence : hooks d'état](https://docs.prefect.io/v3/how-to-guides/workflows/state-change-hooks).

Ne pas transformer une exception en chaîne « erreur » retournée comme un résultat normal.
Laisser remonter l'échec après journalisation ; si vous manipulez des objets State ou Future,
vérifier explicitement leurs résultats pour ne pas masquer un échec de tâche.

**Preuves :** avec des réponses simulées, observer 503 puis succès, ensuite une entrée invalide
sans retry. Montrer que les étapes dépendantes ne publient rien après l'échec définitif.
**Question :** pourquoi un retry de l'évaluation peut-il être plus risqué qu'un retry d'un GET ?

## 5 — Orchestrer le PULL et les lots PUSH

Brancher les deux chemins du TP2 sur **le même flow**. Le mode, le snapshot et les identifiants de
provenance restent dans la configuration ou le contexte existant. Ne pas créer deux versions des modèles métier.

Pour le PULL, votre commande lance le flow qui acquiert les données puis poursuit les quatre étapes.
Pour le PUSH, conserver `POST /games`, la validation, la déduplication et la réservation atomique
d'un lot de 500 jeux. Le worker applicatif du TP2 appelle le flow après réservation, hors du POST.
Pour ce socle, une seule instance de ce worker traite les lots séquentiellement.

**Distinguer les exécutants :** ce worker applicatif sait lire votre table de jobs ; ce n'est pas
un worker Prefect. Ajouter `@flow` ne dispense pas de votre stockage durable et de votre logique
de réservation. Le POST doit continuer à répondre sans attendre l'entraînement.

Persister le `flow_run_id` dès qu'il est disponible et conserver le `mlflow_run_id` pour la reprise.
Faire correspondre les états de votre job avec l'issue réelle du flow. Un retry en cours n'est pas
encore l'échec définitif du lot. Distinguer, dans le diagnostic, un échec métier, un timeout et un arrêt brutal.

Rejouer le scénario, avec une campagne PUSH dédiée aux tests :

```sh
uv run --locked python simulateur_push.py 499
uv run --locked python simulateur_push.py 1
uv run --locked python simulateur_push.py 1
```

Inspecter les compteurs entre les commandes. Si tous les jeux sont valides et distincts : aucun flow
d'entraînement à 499, un flow pour le premier lot à 500, puis un jeu en attente à 501.
Rejouer un même événement ne doit déclencher aucun flow supplémentaire.

Simuler ensuite un échec de publication sur ce lot, puis une reprise contrôlée. Un nouveau flow de
reprise peut être nécessaire : le relier au même lot et à la publication initiale. Montrer que la
reprise ne crée pas une seconde version identique déjà publiée. Préserver les règles de qualification
du TP3 et le périmètre `demo-only` des modèles synthétiques.

**Objectif :** tableau de correspondance job/flow/MLflow, compteurs 499/500/501 et versions avant/après reprise.
**Question :** quelles garanties viennent de Prefect et lesquelles viennent encore de votre code ?

## 6 — Déclencher un flow depuis un déploiement local

**Problème :** l'interface montre les exécutions passées, mais un appel Python direct n'est pas encore
un lancement planifié. Créer vous-mêmes un petit point d'entrée Python de déploiement qui importe
le flow existant et utilise **`flow.serve`**. Ce fichier appartient à votre projet étudiant ; il n'est
pas fourni dans le support et ne contient pas de logique d'entraînement supplémentaire.

Nommer le déploiement par binôme. Fournir ses paramètres par défaut, sa description et une version
liée au code. Protéger le lancement par `if __name__ == "__main__"`, notamment sous Windows.
Le processus `serve` reste actif et exécute les runs dans des sous-processus locaux : votre code,
les données et les trois variables d'environnement doivent y être disponibles.
Ce mode n'exige pas de work pool ni de worker Prefect supplémentaire.
[Référence : exécution locale avec serve](https://docs.prefect.io/v3/how-to-guides/deployment_infra/run-flows-in-local-processes).

Commencer sans planning, puis déclencher une exécution depuis l'interface Prefect avec le paramètre
`config_path`. Utiliser un chemin absolu vers la configuration. La préparation d'un dossier de sortie
neuf par exécution doit être gérée par le code/configuration, sans réutiliser aveuglément le dossier
du run précédent. Consigner la configuration effectivement utilisée dans MLflow.

Ajouter ensuite un planning à intervalle, par exemple dix minutes, et observer **une** exécution
planifiée. Utiliser un snapshot ou le cache HTTP du PULL pour cet essai, sans multiplier les appels
publics. Configurer `limit=1` pour limiter les exécutions simultanées de ce runner local.
Cette limite ne contrôle pas un autre processus qui appelle directement le flow : arrêter le
worker PUSH pendant l'essai planifié pour garder le socle séquentiel.

Désactiver le planning après l'observation puis arrêter `serve` avec Ctrl+C. Vérifier son état
dans l'interface : un serveur allumé sans exécutant disponible ne suffit pas à exécuter votre code.
Le mode `serve` met normalement son planning en pause à l'arrêt propre ; ne pas supposer qu'une
coupure brutale aura exactement le même effet.

**Objectif :** un lancement depuis l'interface et un lancement planifié, avec paramètres, logs et liens MLflow.
**Question :** où s'exécute le code quand le serveur est dans Docker et `serve` sur votre poste ?

## 7 — Expérimenter un cache sans perdre la traçabilité

**Problème :** rejouer un calcul déterministe coûte du temps, mais mettre toute une étape en cache
peut aussi supprimer ses logs métier ou ses écritures MLflow.

Dans le prétraitement, isoler une sous-fonction **pure** coûteuse ou représentative : par exemple la
construction déterministe des features à partir d'un snapshot. La tâche mère reste exécutée pour
tracer le nouveau run. Le calcul isolé ne publie rien, n'ouvre aucun run MLflow et ne retourne pas
un contexte contenant un ancien `run_id`.

Configurer uniquement cette sous-tâche avec `persist_result=True`, un stockage local de résultats
identifié et une clé de cache explicite. Celle-ci doit intégrer l'empreinte du contenu du snapshot,
les paramètres pertinents et une version du code de préparation, y compris ses helpers.
Un chemin identique ne prouve pas que son contenu est identique. Une clé incluant systématiquement
le nouveau `flow_run_id` ne permettra pas la réutilisation entre deux flows.
[Référence : cache et persistance des résultats](https://docs.prefect.io/v3/concepts/caching).

Conserver le stockage accessible entre les processus locaux. Le volume du serveur Prefect ne
sauvegarde pas automatiquement les résultats Python du poste. Si le résultat contient des chemins,
vérifier que les fichiers référencés existent encore. Ne pas y placer des connexions ou des loggers.

Exécuter trois essais :

1. Même snapshot, mêmes paramètres : observer un calcul puis une réutilisation.
2. Contenu du snapshot modifié sous le même nom : vérifier un nouveau calcul.
3. Paramètre ou version du prétraitement modifié : vérifier l'invalidation.

Ne pas mettre en cache l'acquisition d'une source évolutive sans politique de fraîcheur, ni les
fonctions mères qui publient dans MLflow. Le cache HTTP du TP2, le cache de calcul Prefect et
l'idempotence d'une publication répondent à des besoins différents.

**Objectif :** mêmes résultats au cas nominal, calculs invalidés dans les deux autres cas, et traçabilité
MLflow présente pour chaque nouveau pipeline malgré la réutilisation d'un calcul.

## 8 — Alerter dans un canal Teams avec Prefect

**Situation :** un flow échoue la nuit ; ses logs sont disponibles, mais personne ne consulte
l'interface. Construire une alerte qui permette de retrouver rapidement l'incident et ses conséquences.

### A. Préparer le canal et son bot de notification

Utiliser un canal Teams standard dédié au TP et l'application **Workflows / Power Automate**.
Prévoir un compte de l'établissement autorisé à créer ces workflows et à publier dans ce canal.
La disponibilité dépend des règles et licences du tenant ; vérifier ce prérequis avant la séance.

Créer un workflow à partir du modèle de réception d'un webhook Teams, ou du déclencheur
**When a Teams webhook request is received**, puis configurer la publication dans le canal par
le **bot Workflows (Flow bot)**. Ce bot fournit l'identité de publication ; développer une application
bot Azure personnalisée n'est pas nécessaire pour cet exercice. Utiliser Workflows plutôt que
les anciens connecteurs Office 365 en cours de retrait.
[Référence Microsoft : notifications entrantes avec Workflows](https://support.microsoft.com/en-us/workflows/send-messages-in-teams-using-incoming-webhooks).

Choisir le mode d'authentification autorisé par l'établissement. Le parcours simple du block webhook
suppose une URL appelable sans jeton Entra, si le tenant autorise ce mode ; son URL signée est alors
un secret. Un endpoint limité aux utilisateurs du tenant exige une authentification supplémentaire :
le simple stockage de son URL dans Prefect ne fournit pas de jeton. Ne pas désactiver une règle du
tenant pour contourner cette contrainte ; utiliser le canal préparé par l'enseignant ou le repli ci-dessous.
[Référence : déclencheur et authentification Teams](https://learn.microsoft.com/en-us/connectors/teams/).

Conserver l'URL hors Git, logs, captures et artefacts MLflow. Nommer le workflow et son propriétaire ;
prévoir un copropriétaire pour que le canal reste utilisable si ce compte n'est plus disponible.
[Référence : fonctionnement et limites des webhooks Teams](https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/what-are-webhooks-and-connectors).

### B. Brancher une automation sur les événements Prefect

Le chemin attendu est :

```text
Flow en échec → événement Prefect → automation → block de notification
             → webhook Workflows → bot dans le canal Teams
```

Créer un block **Microsoft Teams Webhook** dans Prefect et y stocker la destination.
Le SDK expose `prefect.blocks.notifications.MicrosoftTeamsWebhook`, avec les opérations de
sauvegarde, chargement et `notify`. Vérifier la réception d'un message de test explicitement marqué
« TEST TP4 » avant de brancher l'automation. Vérifier aussi la compatibilité de l'URL et du format
de carte avec le workflow choisi ; le block courant vise les URLs Workflows.
[Référence : blocks de notification](https://reference.prefect.io/prefect/blocks/notifications/).

Créer ensuite une automation **avec le SDK Python**, dans un point d'entrée de configuration séparé
du pipeline. Explorer `Automation`, `EventTrigger` et `SendNotification` ; l'action doit référencer
l'identifiant du block enregistré. Conserver l'identifiant de l'automation pour la modifier sans
créer une copie à chaque lancement. L'interface sert à vérifier la configuration et les événements.
[Référence : création d'automations avec Python](https://docs.prefect.io/v3/how-to-guides/automations/creating-automations).

Pour le socle, choisir un déclencheur réactif sur `prefect.flow-run.Failed` et
`prefect.flow-run.Crashed`, limité au flow ou au déploiement de votre binôme. Inspecter les ressources
de l'événement pour construire le filtre ; un filtre sur le déploiement ne couvre pas automatiquement
les appels directs du worker PUSH. Vérifier les deux chemins que vous souhaitez superviser.

Ne pas alerter sur chaque tentative de task ni sur `AwaitingRetry` : un incident transitoire résolu
par les retries doit rester silencieux. Une automation réagit aux événements reçus ; une machine
qui disparaît sans événement d'échec exige un mécanisme de détection d'absence, hors du socle.

L'envoi de l'automation est réalisé côté serveur Prefect : le conteneur doit pouvoir joindre Teams
en HTTPS, et les services d'événements/automations doivent fonctionner. Aucune ouverture entrante
de votre serveur local sur Internet n'est nécessaire. Contrôler les événements et les journaux du
service si le block fonctionne depuis le poste mais pas depuis l'automation.

### C. Rendre l'alerte exploitable et vérifier ses limites

Le message doit contenir au minimum le nom du flow, son identifiant, l'état terminal, la date,
le binôme/environnement et une référence permettant d'ouvrir l'exécution Prefect.
Ajouter le mode PULL/PUSH, le `batch_id`, le `mlflow_run_id` et l'étape en erreur lorsqu'ils sont
disponibles ; sinon afficher explicitement « indisponible ». Les variables locales du processus
ne sont pas automatiquement accessibles au modèle de notification : choisir comment exposer ces
références dans les métadonnées du run et tester le rendu avec un événement réel.
Les actions supportent des modèles de message ; consulter leur contexte avant de choisir les champs.
[Référence : actions et notifications](https://reference.prefect.io/prefect/events/actions/).

Une URL `localhost:4200` n'ouvre la bonne interface que sur le poste qui héberge cette instance.
Mentionner le poste et conserver les identifiants dans le message ; ne pas présenter ce lien comme
accessible à toute l'équipe. N'exposer ni Prefect ni MLflow sur Internet pour cette démonstration.

| Essai contrôlé | Observation attendue |
|---|---|
| Erreur 503 suivie d'une réussite | Aucun message d'échec définitif |
| Donnée invalide, flow en échec | Une alerte nominale avec le bon run, sans modèle publié indûment |
| Flow d'un autre binôme | Aucun message dans votre canal |
| Modèle rejeté, flow techniquement réussi | Pas d'alerte technique ; distinguer refus métier et panne |
| Destination Teams indisponible | Échec de notification observable ; état du flow initial conservé |

Pour la dernière ligne, utiliser une copie de la destination dédiée au test. Vérifier l'historique
de l'action Prefect **et** celui du workflow Teams : une réponse HTTP acceptée ne prouve pas que
la carte est apparue dans le canal. Une panne de notification ne doit pas relancer l'entraînement.

Viser un message par événement terminal dans le cas nominal, sans promettre une livraison
« exactement une fois ». Identifier le run et l'événement pour reconnaître un doublon ; expliquer
où dédupliquer si un retry d'envoi peut republier une carte. Ne pas activer simultanément un hook
et une automation qui envoient tous deux la même alerte.

Comparer enfin un envoi depuis `on_failure` à cette automation : où s'exécute chaque mécanisme,
lequel dépend encore du processus du flow, et lequel peut réagir à un événement reçu après son arrêt ?
Désactiver l'automation de test à la fin, sans supprimer les preuves de fonctionnement.

**Objectif :** configuration reproductible par SDK sans secret, identifiants d'automation/block,
événement déclencheur, résultat de l'action et message réellement reçu dans Teams.
**Question :** qui détecte qu'un système d'alerting ne parvient plus à alerter ?

**Repli si Teams est indisponible :** réaliser la même automation avec une destination HTTP de test
contrôlée, via un block de notification adapté. Le récepteur doit être joignable depuis le conteneur
Prefect ; `localhost` dans ce conteneur n'est pas le poste hôte. Conserver la preuve du POST et du
contenu rendu, puis indiquer que la livraison Teams reste non validée. Ce repli permet d'étudier
Prefect sans prétendre avoir réalisé l'intégration Teams.

## 9 — Audit de fonctionnement et bilan

Faire reprendre une exécution par un autre binôme, sans explication orale. Depuis l'interface,
il doit identifier l'étape lente ou en échec, expliquer les tentatives, retrouver le snapshot et
les modèles, puis proposer une reprise qui respecte le contrat métier.

| Vérification | Critère d'acceptation |
|---|---|
| Cas nominal | Un flow, quatre tâches mères visibles, dépendances cohérentes et sorties MLflow accessibles |
| Erreur temporaire | Nombre de tentatives borné, délai visible et réussite finale justifiée |
| Erreur définitive | Échec explicite ; aucune publication ou qualification positive indue |
| PUSH | Réservation durable inchangée, suivi du lot, absence de doublons de publication |
| Déploiement | Lancements manuel et planifié observés ; planning désactivé à la fin |
| Cache | Réutilisation prouvée et invalidation sur contenu, paramètres et version |
| Alerting | Échec terminal notifié, retries transitoires silencieux, destination et message vérifiés |

Consulter les états tels que `Completed`, `Failed`, `AwaitingRetry` ou `Crashed` dans leur contexte ;
un timeout peut avoir un nom d'état spécifique. Rapporter l'état réellement observé et sa cause,
sans assimiler tous les arrêts à la même panne.
[Référence : états](https://docs.prefect.io/v3/concepts/states).

Exécuter aussi vos tests existants : ajouter Prefect ne doit pas changer les filtres, les cibles,
les règles de qualification ou les prédictions à configuration identique. Compléter les tests
avec les incidents contrôlés du TP. Tester les fonctions métier seules ne prouve pas le suivi
Prefect : conserver au moins une preuve d'intégration réelle pour chaque scénario principal.

## Livrables

- Projet uv enrichi avec SDK Prefect, quatre tâches mères et flow commun PULL/PUSH.
- Logs contextualisés et correspondance des identifiants métier, Prefect et MLflow.
- Politique de retries/timeouts, tests d'incidents et mécanisme de finalisation du run MLflow.
- Point d'entrée de déploiement Python, procédure de démarrage/arrêt et preuve du planning désactivé.
- Expérience de cache reproductible, rapport bref et identifiants des runs vérifiables.
- Automation d'alerte créée par SDK, bot Workflows configuré, preuves de réception et d'échec
  de notification ; secrets exclus et automation de test désactivée. Signaler tout repli sans Teams.

L'évaluation porte sur l'orchestration observable et correcte. Multiplier les décorateurs, réussir
un entraînement ou produire uniquement des captures d'écran ne suffit pas à démontrer les reprises.

## Indices graduels

1. Obtenir d'abord le graphe séquentiel nominal avec cache et retries désactivés.
2. Ajouter ensuite les logs et les identifiants croisés, puis un incident à la fois.
3. Un helper technique de finalisation permet de conserver un `main.py` centré sur les quatre appels.
4. Un retry peut rejouer tout le corps d'une tâche : lister ses effets avant de l'activer.
5. Pour le cache, séparer un résultat métier réutilisable du contexte particulier d'une exécution.

Les pages en ligne évoluent ; la séance
conserve **Prefect 3.8.7**, comme le Compose commun. Vérifier les signatures dans l'environnement
installé avant de reprendre un exemple destiné à une autre version.
