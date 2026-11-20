# Licencje komponentów zewnętrznych

**Archiwum** (kod w `Sources/`) jest udostępnione na licencji MIT (plik `LICENSE`).

Instalator (DMG) zawiera nieprzerobiony plik wykonywalny **7-Zip (`7zz`)** autorstwa Igora Pavlova,
używany jako silnik kompresji. 7-Zip jest udostępniany na licencji GNU LGPL
z ograniczeniem „unRAR restriction” dla kodu dekompresji RAR.

- Strona projektu i kod źródłowy: <https://www.7-zip.org/>
- Licencja: <https://www.7-zip.org/license.txt>

Archiwum uruchamia `7zz` jako osobny proces (nie linkuje go statycznie), więc można go zastąpić
własną wersją: wystarczy podmienić plik `Archiwum.app/Contents/Resources/7zz` (i ponownie podpisać aplikację)
albo zbudować aplikację ze źródeł z własnym `7zz` w `PATH` (patrz `build.sh`).

Ikony systemowe pochodzą z SF Symbols (Apple) i są używane zgodnie z licencją SF Symbols.
