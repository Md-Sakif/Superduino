-- Opening the wizard refreshes the board list when online; Refresh does it again.
return {
  run = function(T)
    local v = T.open_wizard()
    T.wait_until(function() return v.index.state == "updated" end, 10, "the board list to be refreshed")
    T.match(v:index_status(), "Board list updated just now", "status says it was updated")
    local _, count = T.fake_cli_calls():gsub("core update%-index", "")
    T.eq(count, 1, "update-index ran once")
    T.wait(0.1) -- let the page lay itself out again with Refresh enabled
    local refresh
    for _, link in ipairs(v.current_layout.tools) do if link.id == "tool:refresh" then refresh = link end end
    v:on_mouse_pressed("left", refresh.x + 2, refresh.y + 2, 1)
    T.wait_until(function()
      local _, n = T.fake_cli_calls():gsub("core update%-index", "")
      return n == 2 and v.index.state == "updated"
    end, 10, "Refresh to run update-index again")
  end,
}
