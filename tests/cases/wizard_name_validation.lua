-- The name is checked while typing, with plain explanations.
return {
  before = function(T)
    T.mkdir(T.home .. "/Arduino/Taken")
  end,
  run = function(T)
    local v = T.open_wizard()
    T.key("return"); T.key("return"); T.key("return")
    T.name_step(v)
    local cases = {
      { "My Blink", "Spaces are not allowed" },
      { "-x", "must start with a letter" },
      { "a.", "cannot end with" },
      { "caf\u{e9}", "Only letters" },
      { string.rep("a", 64), "at most 63" },
      { "Taken", "already exists" },
    }
    for _, case in ipairs(cases) do
      v.name = case[1]
      T.match(v:name_problem() or "", case[2], "name " .. case[1]:sub(1, 12) .. " is rejected")
    end
    v.name = "Good_Name-1.0"
    T.eq(v:name_problem(), nil, "a valid name is accepted")
    v.name = ""
    T.key("backspace")
    T.eq(v.step, 5, "backspace on an empty name does not go back")
    v.name = "Taken"
    T.key("return")
    T.match(v.message or "", "already exists", "creating with a bad name explains why")
    T.eq(v.step, 5, "stays on the name step")
  end,
}
