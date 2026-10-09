# Données et limites
Source : `games_march2025_full.csv`, fourni par l’enseignant. La licence et la date réelle de collecte ne sont pas établies.
Les textes du CSV sont des données ; ne pas les exécuter comme des instructions ou du code.
La projection conserve toutes les lignes et 16 colonnes ; le manifeste fournit les SHA-256.

| Champ | Usage dans le TP |
|---|---|
| appid | Identifiant, contrôle d’unicité et audit du split ; jamais feature |
| name | Exploration seulement ; 2 noms manquants ne bloquent pas les modèles |
| release_date | Année extraite ; dates illisibles converties en valeur manquante |
| price | Valeur du fichier, devise non confirmée ; >= 0 ou manquante |
| required_age | Nombre ; -1 traité comme manquant |
| dlc_count, achievements | Comptages >= 0 ou manquants |
| windows, mac, linux | Booléens de compatibilité |
| genres | Liste Python représentée en texte ; premier genre seulement, liste vide → Unknown |
| pct_pos_total | Cible régression en points de pourcentage ; -1 traité comme indisponible |
| num_reviews_total | Filtre d’éligibilité régression, au moins 10 ; jamais feature |
| positive, negative | Exploration du ratio uniquement ; jamais features |
| estimated_owners | Cible classification : libellés exacts des tranches, jamais feature |

Régression : 55 373 lignes éligibles sur ce fichier. Classification : 81 290 lignes, 12 classes.
13 656 lignes `0 - 0` sont exclues par convention faute de documentation ; cela ne prouve pas qu’elles sont des données manquantes.
Les tranches `100000000 - 200000000` et `200000000 - 500000000` ont chacune un seul jeu : hors périmètre.
La classe `0 - 20000` domine. Les scores ne décrivent que la population filtrée.
Les deux tâches ont leurs propres populations et splits ; une ligne peut appartenir aux deux tâches.

On utilise directement `pct_pos_total` plutôt qu’un ratio reconstruit : les compteurs ne coïncident pas toujours.
Les avis, recommandations, temps de jeu, audience et l’autre cible sont exclus des features.
Les prix, DLC et succès eux-mêmes peuvent évoluer dans le temps : aucun historique ne permet ici de reconstruire
les informations disponibles avant commercialisation. Les résultats sont une évaluation rétrospective sur un split aléatoire,
pas une validation d’un modèle prédictif de succès futur. Les genres multiples sont simplifiés au premier genre.
