-- Offline on a fresh machine: an explanation and Try Again, which works once online.
return {
  before = function(T) T.fake_cli({ offline = true, has_index = false, installed = {} }) end,
  run = function(T)
    local core = require "core"
    T.command("arduino:new-project")
    local v = T.wait_until(function()
      local view = core.active_view
      return tostring(view) == "NewProjectView" and not view.loading and view
    end, 10, "wizard")
    T.check(v.load_error ~= nil, "loading fails")
    T.eq(require("plugins.arduino.cli").explain_error(v.load_error),
      "Could not connect to the internet. Check your connection and try again.", "explains it is offline")
    T.eq(v.current_layout.next.text, "Try Again", "offers Try Again")
    T.shot("offline-no-index")
    T.fake_cli_set("offline", false)
    T.key("return")
    T.wait_until(function() return not v.loading and not v.load_error end, 10, "retry to load")
    T.eq(T.selected(v), "Arduino", "the list appears after going online")
  end,
}
