# Poznámky k vydaniu

Každá zmena typu `feat`, `fix` alebo `perf` pridá v tom istom pull requeste jeden súbor sem:

- `feat-<krátky-názov>.md` pre novinku (sekcia „Čo je nové“),
- `fix-<krátky-názov>.md` alebo `perf-<krátky-názov>.md` pre opravu (sekcia „Opravy“).

Súbor obsahuje jednu odrážku po slovensky, napísanú pre advokáta, ktorý aplikáciu používa, nie pre vývojára: čo sa zmenilo, kde to uvidí a čo má prípadne urobiť. Bez hash commitov, názvov tried a súborov. Vzor:

```markdown
- **Chevron7 povie, keď chýba ovládač karty.** Ak je karta v čítačke, ale na Macu nie je jej ovládač, ...
```

`scripts/release-notes.sh` pri vydaní zoberie súbory pridané od posledného vydania v poradí, v akom pribudli. Ručne napísaný `docs/releases/vX.Y.Z.md` má prednosť pred všetkými. Podpis aplikácie a notarizáciu poznámky nespomínajú.
