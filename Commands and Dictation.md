### Command Mode Grammar & Dispatch

When in **Command Mode**, spoken utterances are parsed into discrete structural editing operations applied to the active `NSTextView` / `NSTextLayoutManager` or trigger session controls.

#### System & Session Controls

* `Send prompt` *(Submits Left Pane prompt buffer to the LLM)*
* `Stop` *(Halts AVSpeechSynthesizer playback; enters Manual/Editing Mode on Right Pane)*
* `Play` *(Resumes/starts AVSpeechSynthesizer playback; locks voice to Command Mode)*
* `Got it` *(Acknowledges response, stops TTS, shifts focus to Left Pane, activates Dictation Mode)*

#### Text Selection

* `Select that`
* `Select all`
* `Select <phrase>`
* `Select previous`
* `Select next`
* `Select character`
* `Select previous character`
* `Select next character`
* `Select word`
* `Select previous word`
* `Select next word`
* `Select sentence`
* `Select previous sentence`
* `Select next sentence`
* `Select paragraph`
* `Select previous paragraph`
* `Select next paragraph`
* `Select line`
* `Select previous line`
* `Select next line`
* `Select <count> characters`
* `Select previous <count> characters`
* `Select next <count> characters`
* `Select <count> words`
* `Select previous <count> words`
* `Select next <count> words`
* `Select <count> sentences`
* `Select previous <count> sentences`
* `Select next <count> sentences`
* `Select <count> paragraphs`
* `Select previous <count> paragraphs`
* `Select next <count> paragraphs`
* `Select <count> lines`
* `Select previous <count> lines`
* `Select next <count> lines`
* `Extend selection <count> characters`
* `Extend selection back <count> characters`
* `Extend selection <count> words`
* `Extend selection back <count> words`
* `Extend selection <count> sentences`
* `Extend selection back <count> sentences`
* `Extend selection <count> paragraphs`
* `Extend selection back <count> paragraphs`
* `Extend selection <count> lines`
* `Extend selection back <count> lines`
* `Deselect that`

#### Text Navigation

* `Move down`
* `Move up`
* `Move left`
* `Move right`
* `Scroll up`
* `Scroll down`
* `Scroll to top`
* `Scroll to bottom`
* `Move to beginning`
* `Move to end`
* `Move to beginning of word`
* `Move to end of word`
* `Move to beginning of sentence`
* `Move to end of sentence`
* `Move to beginning of paragraph`
* `Move to end of paragraph`
* `Move to beginning of line`
* `Move to end of line`
* `Move to beginning of selection`
* `Move to end of selection`
* `Move forward <count> characters`
* `Move back <count> characters`
* `Move forward <count> words`
* `Move back <count> words`
* `Move forward <count> sentences`
* `Move back <count> sentences`
* `Move forward <count> paragraphs`
* `Move back <count> paragraphs`
* `Move forward <count> lines`
* `Move back <count> lines`
* `Move right <count> characters`
* `Move left <count> characters`
* `Move right <count> words`
* `Move left <count> words`
* `Move right <count> sentences`
* `Move left <count> sentences`
* `Move right <count> paragraphs`
* `Move left <count> paragraphs`
* `Move right <count> lines`
* `Move left <count> lines`
* `Move after <phrase>`
* `Move before <phrase>`

#### Text Editing (Supported on Both Panes when Not Speaking)

* `Replace <phrase> with <phrase>`
* `Insert <phrase> after <phrase>`
* `Insert <phrase> before <phrase>`
* `Correct that` *(Opens native macOS spelling/grammar replacement panel via `showGuessPanel:`)*
* `Correct <phrase>`
* `Undo that`
* `Redo that`
* `Cut that`
* `Copy that`
* `Paste that`
* `Capitalise that`
* `Capitalise <phrase>`
* `Lowercase that`
* `Lowercase <phrase>`
* `Uppercase that`
* `Uppercase <phrase>`
* `Bold that`
* `Bold <phrase>`
* `Italicise that`
* `Italicise <phrase>`
* `Underline that`
* `Underline <phrase>`

#### Text Deletion

* `Delete that`
* `Delete all`
* `Delete <phrase>`
* `Delete character`
* `Delete previous character`
* `Delete next character`
* `Delete word`
* `Delete previous word`
* `Delete next word`
* `Delete sentence`
* `Delete previous sentence`
* `Delete next sentence`
* `Delete paragraph`
* `Delete previous paragraph`
* `Delete next paragraph`
* `Delete line`
* `Delete previous line`
* `Delete next line`
* `Delete <count> characters`
* `Delete previous <count> characters`
* `Delete next <count> characters`
* `Delete <count> words`
* `Delete previous <count> words`
* `Delete next <count> words`
* `Delete <count> sentences`
* `Delete previous <count> sentences`
* `Delete next <count> sentences`
* `Delete <count> paragraphs`
* `Delete previous <count> paragraphs`
* `Delete next <count> paragraphs`
* `Delete <count> lines`
* `Delete previous <count> lines`
* `Delete next <count> lines`

---

### Dictation Mode Directives & Lexicon

In **Dictation Mode**, speech streams continuously into whichever pane currently holds keyboard focus:

| Dictation Directive | Execution Behavior |
| --- | --- |
| `<phrase>` | Literal speech-to-text insertion with automatic punctuation. |
| `<phrase> emoji` | Converts `<phrase>` to Unicode emoji equivalent (e.g., `"fire emoji"` $\$rightarrow `"🔥"`). |
| `Type <phrase>` | Verbatim character insertion; bypasses grammar rules or auto-formatting. |
| `Insert date` | Inserts localized current date string (`DateFormatter.localizedString`). |
| `Press Return key` | Inserts newline `\n` into the active text buffer. |
| `Press Escape key` | Clears active suggestions, dismissal overlays, or selections. |
| `Add to vocabulary` | Extracts selected word/phrase and persists it into `SFVocabulary.shared().setCustomVocabularyStrings(..., for: .userContext)`. |
| `"Command Mode"` *(Voice Trigger)* | Switches voice recognition engine into **Command Mode** without inserting the phrase. |
| `Send prompt` | Submits the Left Pane prompt buffer to the LLM without leaving Dictation Mode; the phrase is not inserted. Recognised only as a whole utterance, so a sentence that merely contains the words is still dictated. |
