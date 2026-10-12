# Results — variant `fixed`

Times are medians; `DNF` = did not finish within the timeout.

## Terminal editors

### Time to first content paint (tty metric)

| editor | 100 lines | 1,000 lines | 10,000 lines | 100,000 lines | 1,000,000 lines |
|---|---|---|---|---|---|
| emacs | 91 ms | 79 ms | 81 ms | 93 ms | DNF |
| kak | 304 ms | 298 ms | 299 ms | 306 ms | 350 ms |
| micro | 55 ms | 49 ms | 47 ms | 62 ms | 146 ms |
| nvim | 201 ms | 231 ms | 247 ms | 206 ms | 218 ms |
| vim | 92 ms | 78 ms | 77 ms | 80 ms | 176 ms |

### Open and quit (hyperfine; includes process spawn + teardown)

| editor | 100 lines | 1,000 lines | 10,000 lines | 100,000 lines | 1,000,000 lines |
|---|---|---|---|---|---|
| emacs | 34 ms | 34 ms | 39 ms | 44 ms | — |
| nvim | 18 ms | 18 ms | 19 ms | 26 ms | 77 ms |
| vim | 16 ms | 15 ms | 16 ms | 27 ms | 129 ms |

## GUI editors

### Cold start (fresh process)

| editor | 100 lines | 1,000 lines | 10,000 lines | 100,000 lines | 1,000,000 lines |
|---|---|---|---|---|---|
| bbedit | DNF | DNF | DNF | DNF | DNF |
| codeedit | DNF | DNF | DNF | DNF | DNF |
| nova | DNF | DNF | DNF | DNF | DNF |
| openedit | 424 ms | 451 ms | 385 ms | 431 ms | 532 ms |
| sublime | 488 ms | 558 ms | 634 ms | 834 ms | 955 ms |
| textedit | 354 ms | 449 ms | 462 ms | 490 ms | 700 ms |
| vscode | DNF | DNF | DNF | DNF | DNF |
| vscode-bg | 1780 ms | — | — | — | — |
| zed | 513 ms | 498 ms | 512 ms | 531 ms | 749 ms |

### Warm open (running instance)

| editor | 100 lines | 1,000 lines | 10,000 lines | 100,000 lines | 1,000,000 lines |
|---|---|---|---|---|---|
| bbedit | DNF | DNF | DNF | DNF | 197 ms |
| codeedit | DNF | DNF | DNF | DNF | DNF |
| nova | DNF | DNF | DNF | DNF | DNF |
| openedit | 220 ms | 219 ms | 148 ms | 162 ms | 202 ms |
| sublime | 149 ms | 150 ms | 150 ms | 147 ms | 163 ms |
| textedit | 148 ms | 186 ms | 194 ms | 192 ms | 436 ms |
| vscode | DNF | DNF | DNF | DNF | DNF |
| zed | 143 ms | 147 ms | 146 ms | 153 ms | 128 ms |

### Winner per size (time to first paint / interactive window)

| lines | fastest | median | runner-up | median | OpenEdit | median |
|---|---|---|---|---|---|---|
| 100 | micro | 55 ms | emacs | 91 ms | openedit | 220 ms |
| 1,000 | micro | 49 ms | vim | 78 ms | openedit | 219 ms |
| 10,000 | micro | 47 ms | vim | 77 ms | openedit | 148 ms |
| 100,000 | micro | 62 ms | vim | 80 ms | openedit | 162 ms |
| 1,000,000 | zed | 128 ms | micro | 146 ms | openedit | 202 ms |
