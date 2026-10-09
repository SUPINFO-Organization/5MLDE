# 5MLDE — Travaux pratiques MLOps

Un parcours pour industrialiser deux modèles sur des données de jeux Steam : prédire le pourcentage d’avis positifs et la tranche de propriétaires estimés.

1. [TP1 — Industrialisation](TP01_industrialisation/ENONCE.md) : transformer un notebook exploratoire en projet Python.
2. [TP2 — Données dynamiques](TP02_donnees_dynamiques/ENONCE.md) : ingestion par API et validation avec Great Expectations.
3. [TP3 — MLflow](TP03_mlflow/ENONCE.md) : tracer les expériences et versionner les modèles.
4. [TP4 — Prefect](TP04_prefect/ENONCE.md) : orchestrer les workflows et déclencher des alertes.
5. [TP5 — API et supervision](TP05_api_supervision/ENONCE.md) : servir les prédictions, tester la charge et superviser avec PostgreSQL et Grafana.

**Pour commencer :** suivre le [guide d’installation Windows, macOS et Linux](TP00_setup_des_postes/GUIDE_INSTALLATION.md). Il couvre les outils, la stack Docker et le téléchargement du dataset, absent du dépôt Git.

Chaque TP prolonge le code produit au précédent. À partir du TP2, le travail se fait uniquement en Python, sans notebook.
