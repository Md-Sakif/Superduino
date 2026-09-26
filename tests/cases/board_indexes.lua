-- Adding and removing board index URLs from the wizard.
local GOOD = "https://example.com/package_pico_index.json"
local BAD = "https://example.com/wrong_index.json"
return {
  before = function(T)
    T.fake_cli({
      bad_urls = { BAD },
      url_platforms = { [GOOD] = { ["rp2040:rp2040"] = { maintainer = "Earle F. Philhower, III",
        name = "Raspberry Pi Pico/RP2040", latest = "4.0.0", boards = { { "Raspberry Pi Pico", "rp2040:rp2040:rpipico" } } } } },
    })
  end,
  run = function(T)
    local v = T.open_wizard()
    local link
    for _, l in ipairs(v.current_layout.tools) do if l.id == "tool:indexes" then link = l end end
    v:on_mouse_pressed("left", link.x + 2, link.y + 2, 1)
    local panel = v.panel
    T.check(panel ~= nil and panel.input ~= nil, "Board Indexes panel opens")
    T.wait_until(function() return panel.urls end, 5, "configured URLs")
    T.eq(#panel.urls, 0, "no extra indexes yet")

    T.type("not a url"); T.key("return")
    T.match(panel.status or "", "starts with https://", "rejects text that is not a URL")
    T.key("escape")
    T.eq(panel.input, "", "Esc clears the box")

    T.type(GOOD); T.key("return")
    T.wait_until(function() return not panel.busy and panel.status end, 10, "adding the index")
    T.match(panel.status, "1 new board family", "reports the new family")
    T.eq(panel.urls[1], GOOD, "listed")
    T.shot("indexes")

    T.type(BAD); T.key("return")
    T.wait_until(function() return not panel.busy and panel.status end, 10, "adding the bad index")
    T.check(panel.status_is_error, "a failing index is reported")
    T.match(panel.status, "error 404", "the explanation mentions 404")
    T.check(panel.failed[BAD], "marked as failing in the list")
    local remove
    for _, row in ipairs(panel.current_layout.rows) do
      if row.entry.url == BAD then remove = row.remove end
    end
    v:on_mouse_pressed("left", remove.x + 2, remove.y + 2, 1)
    T.wait_until(function() return not panel.busy and #panel.urls == 1 end, 10, "removal")
    T.eq(panel.urls[1], GOOD, "only the good URL is left")

    T.key("backspace")
    T.check(v.panel ~= nil, "Backspace with an empty box does not close the panel")
    T.key("escape")
    T.eq(v.panel, nil, "Esc with an empty box closes the panel")
    T.type("earle"); T.eq(T.selected(v), "Earle F. Philhower, III", "the new vendor is in the list")
  end,
}
