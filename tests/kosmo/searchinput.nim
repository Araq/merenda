## Search controls exercised through the same keyboard dispatch as user input.

import std/[options, strutils, unicode, unittest]

import figdraw
import merenda/nimkit
import merenda/kosmo/kosmo
import fixtures/ui

func center(bounds: Rect): Point =
  initPoint(
    bounds.origin.x + bounds.size.width / 2, bounds.origin.y + bounds.size.height / 2
  )

proc pointForBufferPosition(view: KosmoEditorView, line, column: int): Point =
  require view.editor.revealLocation(line, column)
  view.refresh()
  let
    cursor = view.editor.cursor()
    metrics = view.monoTextMetrics()
  view.pointToWindow(
    initPoint(
      (cursor.column.float32 + 0.5'f32) * metrics.cellWidth,
      (cursor.row.float32 + 0.5'f32) * metrics.lineHeight,
    )
  )

proc pressSearchKey(
    window: Window, key: Key, modifiers: set[nimkit.KeyModifier] = {}
): bool =
  let text =
    case key
    of keyTab: "\t"
    of keyEnter: "\n"
    else: ""
  let event = KeyEvent(text: text, key: key, keyCode: key.ord, modifiers: modifiers)
  result = window.dispatchKeyDown(event)
  discard window.dispatchKeyUp(event)
  discard window.buildRenders()

proc typeSearchText(window: Window, text: string) =
  for rune in text.runes:
    let value = rune.toUTF8()
    let event = KeyEvent(key: keyForText(value), keyCode: keyCodeForText(value))
    discard window.dispatchKeyDown(event)
    require window.dispatchTextInput(value)
    discard window.dispatchKeyUp(event)
    discard window.buildRenders()

proc checkSearchTextRendering(window: Window, field: TextField, expected: string) =
  check field.text() == expected
  var matchingNodes = 0
  for node in window.buildRenders()[DefaultDrawLevel].nodes:
    if node.kind == nkText:
      var rendered: string
      for index in 0 ..< node.textLayout.glyphCount():
        rendered.add node.textLayout.displayRune(index).toUTF8()
      if rendered == expected:
        inc matchingNodes
  check matchingNodes == 1

proc searchFieldFocused(window: Window, field: TextField): bool =
  window.fieldEditorClient() == field

proc checkFloatingSearch(bar: SearchBar, host: View) =
  bar.checkVisibleIn(host)
  check abs(bar.frame().minY - SearchBarInset) < 0.01
  check abs(bar.frame().maxX - (host.bounds().maxX - SearchBarInset)) < 0.01
  check abs(
    bar.frame().size.width -
      min(SearchBarWidth, host.bounds().size.width - 2 * SearchBarInset)
  ) < 0.01

proc newSearchInputFrontend(): KosmoApplication =
  result = newKosmoApplication(
    newApplication("Kosmo search synthetic input"), monitorsGitStatus = false
  )
  result.application.addWindow(result.window)
  result.window.setContentView(result.contentView)
  result.contentView.frame = rect(0, 0, 900, 600)
  result.contentView.layoutSubtreeIfNeeded()
  require result.window.makeFirstResponder(result.editorView)
  result.application.activateWindow(result.window)

proc openSearchInput(frontend: KosmoApplication, inFiles, replacing: bool): TextField =
  var modifiers = frontend.shortcutProfile().primaryModifiers()
  if inFiles:
    modifiers.incl(nimkit.kmShift)
  if replacing:
    modifiers.incl(nimkit.kmOption)
  require frontend.window.pressSearchKey(keyF, modifiers)
  if inFiles:
    result = frontend.searchPanel.queryField
  else:
    result = frontend.editorView.searchField()
  require frontend.window.fieldEditorClient() == result

proc tabToSearchControl(window: Window, control: View): bool =
  for _ in 0 ..< 20:
    if window.firstResponder() == control or window.fieldEditorClient() == control:
      return true
    if not window.pressSearchKey(keyTab):
      return

template withSearchClipboard(body: untyped) =
  block:
    let
      pasteboard {.inject.} = generalPasteboard()
      previousProvider = pasteboard.provider
    pasteboard.provider = nil
    pasteboard.clearContents()
    defer:
      pasteboard.clearContents()
      pasteboard.provider = previousProvider
    body

suite "Kosmo search synthetic input":
  for reversed in [false, true]:
    test "copy Find paste replaces the editor selection when reversed=" & $reversed:
      let
        frontend = newSearchInputFrontend()
        window = frontend.window
        view = frontend.editorView
        editor = view.editor
        source = "needle alpha\nmiddle text\nneedle omega"
        modifiers = frontend.shortcutProfile().primaryModifiers()
      defer:
        frontend.close()
      require editor.handleKey("i")
      require editor.handleTextInput(source)
      require editor.handleKey("Esc")
      require editor.revealLocation(0, 0)
      view.refresh()
      let
        first = view.pointForBufferPosition(0, if reversed: 5 else: 0)
        last = view.pointForBufferPosition(0, if reversed: 0 else: 5)
        bufferId = editor.tabs()[0].id
      require window.mouseDownAt(first)
      require window.mouseDraggedAt(last)
      require window.mouseUpAt(last)
      require editor.selectedText() == "needle"
      require editor.mode() == KosmoEditorMode.Visual
      withSearchClipboard:
        require window.pressSearchKey(keyC, modifiers)
        require pasteboard.plainText() == "needle"
        require window.pressSearchKey(keyF, modifiers)
        require window.searchFieldFocused(view.searchField())
        require window.pressSearchKey(keyV, modifiers)
        check view.searchField().text() == "needle"
        check editor.bufferCursor() == KosmoBufferCursor(line: 2, column: 0)
        check editor.currentSelection().isNone
        check editor.selectedText() == ""
        check editor.mode() == KosmoEditorMode.Normal
        for key in [keyArrowDown, keyArrowUp]:
          require window.pressSearchKey(key)
          check editor.currentSelection().isNone
          check editor.selectedText() == ""
        check editor.bufferCursor() == KosmoBufferCursor(line: 2, column: 0)
        require window.pressSearchKey(keyA, modifiers)
        require window.pressSearchKey(keyBackspace)
        check editor.currentSelection().isNone
        window.typeSearchText("needle")
        require window.pressSearchKey(keyEscape)
        check not view.searchVisible()
        check editor.currentSelection().isNone
        check editor.selectedText() == ""
        check editor.bufferText(bufferId).get() == source
        check pasteboard.plainText() == "needle"

  for styled in [false, true]:
    test "Git diff search pastes and renders " & (if styled: "styled" else: "plain") &
      " clipboard text":
      let
        frontend = newSearchInputFrontend()
        window = frontend.window
        diff = newKosmoGitDiffPanel(
          parseGitDiff(
            "diff --git a/example.nim b/example.nim\n@@ -1 +1 @@\n-old\n" &
              "+ensureArrangement " & repeat("controller.xItems ", 80) & "\n"
          )
        )
      defer:
        frontend.close()
        diff.close()
      require frontend.openDocument(
        newKosmoPaneDocument(
          "test.search-paste",
          "Git Diff",
          diff,
          preferredFirstResponder = diff.markdownView.textView(),
        )
      )
      require diff.waitForDiff()
      discard window.buildRenders()
      require window.makeFirstResponder(diff.markdownView.textView())
      let modifiers = frontend.shortcutProfile().primaryModifiers()
      require window.pressSearchKey(keyF, modifiers)
      let field = diff.searchField()
      withSearchClipboard:
        for value in ["ensureArrangement", " λ ensureArrangement "]:
          checkpoint "Pasting " & repr(value)
          require window.searchFieldFocused(field)
          require pasteboard.replaceWithPlainText(value)
          if styled:
            let storage =
              newTextStorage(value, defaultTextAttributes(color(1, 0, 0), 48))
            require pasteboard.setTextStorage(PasteboardTypeTextStorage, storage)
          require window.pressSearchKey(keyA, modifiers)
          require window.pressSearchKey(keyV, modifiers)
          require diff.waitForDiff()
          window.checkSearchTextRendering(field, value)
          check field.selectedRange() == initTextRange(value.runeLen, 0)
          let editor = TextView(field.currentEditor())
          let caret =
            editor.rectToWindow(editor.layoutManager().caretRect(value.runeLen))
          check caret.minX >= field.rectToWindow(field.bounds()).minX
          check caret.maxX <= field.rectToWindow(field.bounds()).maxX
          let scrollOffset = diff.scrollView.contentOffset()
          require window.pressSearchKey(keyArrowLeft)
          check field.selectedRange() == initTextRange(value.runeLen - 1, 0)
          require window.pressSearchKey(keyArrowRight)
          check field.selectedRange() == initTextRange(value.runeLen, 0)
          check diff.scrollView.contentOffset() == scrollOffset
          require window.pressSearchKey(keyTab)
          require window.pressSearchKey(keyTab, {nimkit.kmShift})
          require window.searchFieldFocused(field)
          window.checkSearchTextRendering(field, value)
        require window.pressSearchKey(keyEscape)
        require window.pressSearchKey(keyF, modifiers)
        window.checkSearchTextRendering(field, " λ ensureArrangement ")

  test "Git diff floating search renders each edit and replaces mouse selections":
    let
      frontend = newSearchInputFrontend()
      window = frontend.window
      diff = newKosmoGitDiffPanel(
        parseGitDiff(
          "diff --git a/example.nim b/example.nim\n@@ -1 +1 @@\n-old\n" &
            "+ensureArrangement controller.xItems\n"
        )
      )
    defer:
      frontend.close()
      diff.close()
    require frontend.openDocument(
      newKosmoPaneDocument(
        "test.search-rendering",
        "Git Diff",
        diff,
        preferredFirstResponder = diff.markdownView.textView(),
      )
    )
    require diff.waitForDiff()
    discard window.buildRenders()
    require window.makeFirstResponder(diff.markdownView.textView())
    require window.pressSearchKey(keyF, frontend.shortcutProfile().primaryModifiers())
    let field = diff.searchField()
    require window.fieldEditorClient() == field
    var query: string
    for rune in "ensureArrangement".runes:
      let value = rune.toUTF8()
      window.typeSearchText(value)
      query.add value
      require diff.waitForDiff()
      check field.selectedRange() == initTextRange(query.runeLen, 0)
      window.checkSearchTextRendering(field, query)

    let
      editor = TextView(field.currentEditor())
      start = editor.layoutManager().caretRect(6)
      finish = editor.layoutManager().caretRect(17)
      firstPoint = editor.pointToWindow(start.center())
      lastPoint = editor.pointToWindow(finish.center())
    require window.mouseDownAt(firstPoint)
    require window.mouseDraggedAt(lastPoint)
    require window.mouseUpAt(lastPoint)
    check field.selectedRange() == initTextRange(6, 11)
    window.typeSearchText("Layout")
    window.checkSearchTextRendering(field, "ensureLayout")

    let regex = diff.buttonWithLabel("Use Reni regular expressions")
    require window.clickAt(regex.pointToWindow(regex.bounds().center()))
    require window.pressSearchKey(keyA, frontend.shortcutProfile().primaryModifiers())
    window.typeSearchText("[")
    check not diff.buttonWithLabel("Next Git diff match").enabled()
    window.checkSearchTextRendering(field, "[")
    require window.pressSearchKey(keyBackspace)
    window.typeSearchText("ensureArrangement")
    require diff.waitForDiff()
    check diff.searchMatchCount() == 1
    window.checkSearchTextRendering(field, "ensureArrangement")

    for width in [560.0'f32, 1000.0'f32]:
      frontend.contentView.frame = rect(0, 0, width, 600)
      frontend.contentView.layoutSubtreeIfNeeded()
      field.containingSearchBar().checkFloatingSearch(diff)
      window.checkSearchTextRendering(field, "ensureArrangement")
    require window.pressSearchKey(keyEscape)
    require window.pressSearchKey(keyF, frontend.shortcutProfile().primaryModifiers())
    window.typeSearchText(" λ ensureArrangement ")
    require window.pressSearchKey(keyTab)
    require window.pressSearchKey(keyTab, {nimkit.kmShift})
    window.checkSearchTextRendering(field, " λ ensureArrangement ")
    check frontend.editorView.editor
    .bufferText(frontend.editorView.editor.tabs()[0].id)
    .get() == ""

  for inFiles in [false, true]:
    let panelName = if inFiles: "file search" else: "editor search"
    for replacing in [false, true]:
      let fieldName = if replacing: "replacement" else: "query"
      test "paste inserts clipboard text into the focused " & panelName & " " & fieldName:
        checkpoint "inFiles=" & $inFiles & ", replacing=" & $replacing
        let frontend = newSearchInputFrontend()
        defer:
          frontend.close()
        let
          window = frontend.window
          query = frontend.openSearchInput(inFiles, replacing)
          bufferId = frontend.editorView.editor.tabs()[0].id
        if replacing:
          require window.pressSearchKey(keyTab)
          require window.pressSearchKey(keyTab)
        let field =
          if not replacing:
            query
          elif inFiles:
            frontend.searchPanel.replacementField
          else:
            frontend.editorView.replacementField()
        require window.fieldEditorClient() == field
        window.typeSearchText("prefix ")
        withSearchClipboard:
          require pasteboard.replaceWithPlainText(" λ needle ")
          require window.pressSearchKey(
            keyV, frontend.shortcutProfile().primaryModifiers()
          )
          check field.text() == "prefix  λ needle "
          require window.pressSearchKey(keyTab)
          check field.text() == "prefix  λ needle "
          check frontend.editorView.editor.bufferText(bufferId).get == ""
          check frontend.editorView.editor.mode() == KosmoEditorMode.Normal
        if not inFiles:
          for width in [560.0'f32, 1000.0'f32]:
            frontend.contentView.frame = rect(0, 0, width, 600)
            frontend.contentView.layoutSubtreeIfNeeded()
            field.containingSearchBar().checkFloatingSearch(frontend.editorView)
            check field.text() == "prefix  λ needle "

      test panelName & " " & fieldName & " owns select all copy cut undo redo and paste":
        checkpoint "inFiles=" & $inFiles & ", replacing=" & $replacing
        let frontend = newSearchInputFrontend()
        defer:
          frontend.close()
        let
          window = frontend.window
          query = frontend.openSearchInput(inFiles, replacing)
          modifiers = frontend.shortcutProfile().primaryModifiers()
          bufferId = frontend.editorView.editor.tabs()[0].id
        if replacing:
          require window.pressSearchKey(keyTab)
          require window.pressSearchKey(keyTab)
        let field =
          if not replacing:
            query
          elif inFiles:
            frontend.searchPanel.replacementField
          else:
            frontend.editorView.replacementField()
        require window.fieldEditorClient() == field
        window.typeSearchText("λ needle")
        withSearchClipboard:
          require pasteboard.replaceWithPlainText("previous clipboard")
          require window.pressSearchKey(keyA, modifiers)
          check field.selectedRange() == initTextRange(0, "λ needle".runeLen)
          require window.pressSearchKey(keyC, modifiers)
          check pasteboard.plainText() == "λ needle"
          require window.pressSearchKey(keyX, modifiers)
          check field.text() == ""
          check pasteboard.plainText() == "λ needle"
          require window.pressSearchKey(keyZ, modifiers)
          check field.text() == "λ needle"
          if nimkit.kmCommand in modifiers:
            require window.pressSearchKey(keyZ, modifiers + {nimkit.kmShift})
          else:
            require window.pressSearchKey(keyY, modifiers)
          check field.text() == ""
          require window.pressSearchKey(keyV, modifiers)
          check field.text() == "λ needle"
          require window.pressSearchKey(keyTab)
          check field.text() == "λ needle"
          check frontend.editorView.editor.bufferText(bufferId).get == ""
          check frontend.editorView.editor.mode() == KosmoEditorMode.Normal

    test "Tab Enter Tab on replacement disclosure preserves the query in " & panelName:
      checkpoint "inFiles=" & $inFiles
      let frontend = newSearchInputFrontend()
      defer:
        frontend.close()
      frontend.window.typeSearchText("ineedle needle")
      require frontend.window.pressSearchKey(keyEscape)
      let
        window = frontend.window
        query = frontend.openSearchInput(inFiles, replacing = false)
        searchView =
          if inFiles:
            View(frontend.searchPanel)
          else:
            View(frontend.editorView)
      window.typeSearchText("needle")
      for expanding in [true, false, true]:
        let disclosure = searchView.buttonWithLabel(
          if expanding: "Show replacement controls" else: "Hide replacement controls"
        )
        require not disclosure.isNil
        require window.tabToSearchControl(disclosure)
        require window.pressSearchKey(keyEnter)
        check query.text() == "needle"
        let replacement =
          if inFiles:
            frontend.searchPanel.replacementField
          else:
            frontend.editorView.replacementField()
        check replacement.hidden == not expanding
        require window.pressSearchKey(keyTab)
        check query.text() == "needle"
        if expanding:
          require window.pressSearchKey(keyTab)
          check window.fieldEditorClient() == replacement
          check query.text() == "needle"
        require window.pressSearchKey(keyTab, {nimkit.kmShift})
        check query.text() == "needle"

    for queryText in [" needle ", " "]:
      test "replacement disclosure preserves literal query " & repr(queryText) & " in " &
        panelName:
        let frontend = newSearchInputFrontend()
        defer:
          frontend.close()
        let
          window = frontend.window
          query = frontend.openSearchInput(inFiles, replacing = false)
          searchView =
            if inFiles:
              View(frontend.searchPanel)
            else:
              View(frontend.editorView)
          disclosure = searchView.buttonWithLabel("Show replacement controls")
        window.typeSearchText(queryText)
        require window.tabToSearchControl(disclosure)
        require window.pressSearchKey(keyEnter)
        check query.text() == queryText
        require window.pressSearchKey(keyTab)
        check query.text() == queryText
