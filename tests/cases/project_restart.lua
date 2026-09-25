-- A restart keeps "no project"; opening a folder switches to it and survives restarts.
return {
  run = function(T)
    local core = require "core"
    if T.phase == 1 then
      T.eq(#core.projects, 0, "starts without a project")
      T.expect_restart()
      core.restart()
    elseif T.phase == 2 then
      T.eq(#core.projects, 0, "still no project after a restart")
      local dir = T.dir .. "/folder"
      local proc = process.start({ "mkdir", "-p", dir })
      proc:wait(5)
      T.expect_restart()
      core.open_project(dir)
    elseif T.phase == 3 then
      T.eq(core.root_project() and core.root_project().path, T.dir .. "/folder", "the opened folder is the project")
      T.expect_restart()
      core.restart()
    else
      T.eq(core.root_project() and core.root_project().path, T.dir .. "/folder", "project kept after a restart")
      T.eq(core.recent_projects[1], T.dir .. "/folder", "folder is first in Recent")
      T.no_errors()
    end
  end,
}
