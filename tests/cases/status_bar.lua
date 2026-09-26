-- The status bar hides the caret position percentage by default.
return {
  run = function(T)
    local core = require "core"
    local item = core.status_view:get_item("doc:position-percent")
    T.check(item ~= nil, "Lite XL still has the item")
    T.eq(item and item.visible, false, "it is hidden")
    T.eq(core.status_view:get_item("doc:position").visible, true, "line:column is still shown")
  end,
}
