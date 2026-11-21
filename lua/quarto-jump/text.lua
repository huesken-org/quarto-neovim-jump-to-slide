-- Text normalization shared by search and sync.
--
-- Both sides (Neovim and the browser JS) reduce text to a list of lowercase
-- words, where a "word" is a run of letters/digits. The JS side uses
-- /[^\p{L}\p{N}]+/u to split; this file approximates that for UTF-8 in Lua.
local M = {}

-- Is this (non-ASCII) code point part of a word? Rough approximation of
-- \p{L}\p{N}: everything is a letter except the common punctuation/symbol blocks.
local function is_word_cp(cp)
  if cp < 0xC0 then
    -- Latin-1 supplement before À: only ª ² ³ µ ¹ º ¼ ½ ¾ are letters/numbers.
    return cp == 0xAA or cp == 0xB2 or cp == 0xB3 or cp == 0xB5 or cp == 0xB9 or cp == 0xBA
      or (cp >= 0xBC and cp <= 0xBE)
  end
  if cp == 0xD7 or cp == 0xF7 then return false end -- × ÷
  if cp >= 0x2000 and cp <= 0x2BFF then return false end -- punctuation, arrows, math, box drawing, …
  if cp >= 0x3000 and cp <= 0x303F then return false end -- CJK punctuation
  if (cp >= 0xFE30 and cp <= 0xFE4F) or (cp >= 0xFF00 and cp <= 0xFF0F) then return false end
  if cp >= 0x1F000 then return false end -- emoji & co.
  return true
end

local function decode(ch)
  local b1, b2, b3, b4 = ch:byte(1, 4)
  if b1 >= 0xF0 and b4 then
    return (b1 - 0xF0) * 0x40000 + (b2 - 0x80) * 0x1000 + (b3 - 0x80) * 0x40 + (b4 - 0x80)
  elseif b1 >= 0xE0 and b3 then
    return (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80)
  elseif b1 >= 0xC0 and b2 then
    return (b1 - 0xC0) * 0x40 + (b2 - 0x80)
  end
  return 0
end

--- Remove markup that never shows up as text in the rendered output.
---@param line string
---@return string
function M.strip_markup(line)
  line = line:gsub("{{<.->}}", " ") -- shortcodes
  line = line:gsub("<!%-%-.-%-%->", " ") -- html comments
  line = line:gsub("</?%a[^>]*>", " ") -- html tags
  line = line:gsub("%]%b()", "]") -- link/image targets
  -- Pandoc attributes {#id .class key="value"}; keep other braces (code!).
  line = line:gsub("%b{}", function(b)
    local inner = b:sub(2, -2)
    if inner:match("^%s*[%.#][%w_-]") or inner:match("^%s*[%w_-]+%s*=") then
      return " "
    end
  end)
  return line
end

--- Split already lowercased text into words.
---@param s string
---@return string[]
function M.split(s)
  s = s:gsub("[^%w\128-\255]+", " ")
  s = s:gsub("[\192-\247][\128-\191]*", function(ch)
    if not is_word_cp(decode(ch)) then return " " end
  end)
  local out = {}
  for w in s:gmatch("%S+") do
    out[#out + 1] = w
  end
  return out
end

--- Lowercase (UTF-8 aware) and split into words.
---@param s string
---@param markup boolean? strip markdown/pandoc markup first
---@return string[]
function M.words(s, markup)
  if not s or s == "" then return {} end
  if markup then s = M.strip_markup(s) end
  return M.split(vim.fn.tolower(s))
end

--- Normalized single string ("word word word").
function M.norm(s, markup)
  return table.concat(M.words(s, markup), " ")
end

return M
