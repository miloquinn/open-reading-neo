# On-demand fonts

The font binaries in this directory are third-party works. They are not
relicensed under Open Reading's AGPL license.

| Flutter family | Upstream font | Purpose | License |
| --- | --- | --- | --- |
| `SourceHanSerifCN` | Noto Serif SC / Source Han Serif | Default App UI serif and optional reading font | SIL OFL 1.1 (`licenses/NotoSerifSC-OFL.txt`) |
| `SourceHanSansCN` | Source Han Sans CN | App UI and reading sans serif | SIL OFL 1.1 (`licenses/SourceHanSans-OFL.txt`) |
| `InstrumentSans` | Instrument Sans | Optional App UI sans serif | SIL OFL 1.1 (`licenses/InstrumentSans-OFL.txt`) |
| `Newsreader` | Newsreader 16pt | Optional editorial reading serif | SIL OFL 1.1 (`licenses/Newsreader-OFL.txt`) |
| `JetBrainsMono` | JetBrains Mono | Optional technical/monospace font | SIL OFL 1.1 (`licenses/JetBrainsMono-OFL.txt`) |
| `HarmonyOSSansSC` | HarmonyOS Sans SC Regular | Optional App UI and reading sans serif | HarmonyOS Sans Fonts License Agreement (`licenses/HarmonyOSSans-License.txt`) |

Font binaries are downloaded on demand and stored in the app-private directory.
HarmonyOS Sans is read unchanged from Huawei's official archive; the application
does not use a third-party font mirror. Keep the corresponding license notice
with every redistributed copy of a font.
