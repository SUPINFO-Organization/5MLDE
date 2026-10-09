# TP 01 — Du notebook au projet Python

Lire [l’énoncé](ENONCE.md). Le notebook exploratoire enrichi est le point de départ à industrialiser.

```sh
uv sync --locked
uv run --locked jupyter lab exploration_steam.ipynb
```

Compléter les quatre fonctions dans `src/ingestion.py`, `src/preprocessing.py`, `src/training.py`
et `src/evaluation.py`. Le `main.py` complet chaîne leurs appels. Après implémentation :

```sh
uv run --locked python main.py --config config.json
```

Les données sont dans `data/`. Aucun corrigé n’est distribué. À partir du TP2, travailler uniquement avec le code Python.
