--[[
  CV Entry Lua Filter for Quarto

  Converts custom divs into format-specific output:

  ::: {.cv-entry}
  **Title here**

  Detail text

  [Date here]{.date}
  :::

  In PDF: \noindent \textbf{Title} \hfill \textit{Date}
          Detail text
  In HTML: flex container with left/right alignment (via CSS)

  Also handles:
  ::: {.cv-contact}   — contact info rows
  ::: {.cv-detail}    — indented detail lines
]]

-- Helper: escape LaTeX special characters in plain text
-- Only escapes chars that commonly appear in CV content
local function escape_latex(text)
  text = text:gsub("&", "\\&")
  text = text:gsub("#", "\\#")
  text = text:gsub("%%", "\\%%")
  return text
end

-- Helper: stringify for LaTeX with escaping
local function latex_stringify(el)
  return escape_latex(pandoc.utils.stringify(el))
end

-- Helper: extract text content from inline elements
local function inlines_to_string(inlines)
  local result = {}
  for _, inline in ipairs(inlines) do
    if inline.t == "Str" then
      table.insert(result, inline.text)
    elseif inline.t == "Space" then
      table.insert(result, " ")
    elseif inline.t == "SoftBreak" then
      table.insert(result, " ")
    elseif inline.t == "Strong" then
      table.insert(result, pandoc.utils.stringify(inline))
    elseif inline.t == "Emph" then
      table.insert(result, pandoc.utils.stringify(inline))
    elseif inline.t == "Link" then
      table.insert(result, pandoc.utils.stringify(inline))
    else
      table.insert(result, pandoc.utils.stringify(inline))
    end
  end
  return table.concat(result)
end

function Div(el)
  -- cv-entry: main entry with optional date
  if el.classes:includes("cv-entry") then
    local left_blocks = {}
    local date_text = nil

    -- Walk through content to find .date spans and separate them
    for _, block in ipairs(el.content) do
      if block.t == "Para" or block.t == "Plain" then
        local new_inlines = {}
        local found_date = false
        for _, inline in ipairs(block.content) do
          if inline.t == "Span" and inline.classes:includes("date") then
            date_text = pandoc.utils.stringify(inline)
            found_date = true
          else
            table.insert(new_inlines, inline)
          end
        end
        -- Only add the block if it has content beyond whitespace
        if #new_inlines > 0 then
          -- Trim trailing spaces
          while #new_inlines > 0 and (new_inlines[#new_inlines].t == "Space" or new_inlines[#new_inlines].t == "SoftBreak") do
            table.remove(new_inlines)
          end
          if #new_inlines > 0 then
            table.insert(left_blocks, pandoc.Para(new_inlines))
          end
        end
      else
        table.insert(left_blocks, block)
      end
    end

    if FORMAT:match("latex") or FORMAT:match("pdf") then
      local result = {}

      if #left_blocks > 0 and left_blocks[1].t == "Para" then
        local left_text = left_blocks[1].content
        if date_text then
          -- Entry with right-aligned date using minipage pair to prevent overflow
          local left_content = ""
          if left_text[1] and left_text[1].t == "Strong" then
            left_content = "\\textbf{" .. latex_stringify(left_text[1]) .. "}"
            for i = 2, #left_text do
              left_content = left_content .. latex_stringify(left_text[i])
            end
          else
            left_content = latex_stringify(pandoc.Para(left_text))
          end
          local raw = "\\noindent"
            .. "\\begin{minipage}[t]{0.70\\textwidth}" .. left_content .. "\\end{minipage}"
            .. "\\hfill"
            .. "\\begin{minipage}[t]{0.28\\textwidth}\\raggedleft\\textit{" .. escape_latex(date_text) .. "}\\end{minipage}"
            .. "\\par\\vspace{1pt}"
          table.insert(result, pandoc.RawBlock("latex", raw))
        else
          -- Entry without date
          local raw = "\\noindent "
          if left_text[1] and left_text[1].t == "Strong" then
            raw = raw .. "\\textbf{" .. latex_stringify(left_text[1]) .. "}"
            for i = 2, #left_text do
              raw = raw .. latex_stringify(left_text[i])
            end
          else
            raw = raw .. latex_stringify(pandoc.Para(left_text))
          end
          raw = raw .. "\\par\\vspace{1pt}"
          table.insert(result, pandoc.RawBlock("latex", raw))
        end

        -- Add remaining blocks as detail lines
        for i = 2, #left_blocks do
          local detail = "\\hspace{1em}" .. latex_stringify(left_blocks[i]) .. "\\par\\vspace{1pt}"
          table.insert(result, pandoc.RawBlock("latex", detail))
        end
      end

      return result
    else
      -- HTML: keep the div structure, CSS handles the layout
      -- Rebuild with left/right spans
      if date_text and #left_blocks > 0 then
        local left_div = pandoc.Div(left_blocks, pandoc.Attr("", {"cv-left"}))
        local right_div = pandoc.Div({pandoc.Para({pandoc.Str(date_text)})}, pandoc.Attr("", {"cv-right"}))
        el.content = {left_div, right_div}
      end
      return el
    end
  end

  -- cv-detail: indented detail line
  if el.classes:includes("cv-detail") then
    if FORMAT:match("latex") or FORMAT:match("pdf") then
      local text = latex_stringify(el)
      return pandoc.RawBlock("latex", "\\hspace{1em}" .. text .. "\\par\\vspace{1pt}")
    else
      return el
    end
  end

  -- cv-contact: contact info row
  if el.classes:includes("cv-contact") then
    if FORMAT:match("latex") or FORMAT:match("pdf") then
      -- Extract left and right parts
      local parts = {}
      for _, block in ipairs(el.content) do
        if block.t == "Para" or block.t == "Plain" then
          for _, inline in ipairs(block.content) do
            if inline.t == "Span" then
              if inline.classes:includes("cv-left") then
                table.insert(parts, {side="left", text=latex_stringify(inline)})
              elseif inline.classes:includes("cv-right") then
                -- For contact right side, handle links specially
                local right_text = ""
                for _, child in ipairs(inline.content) do
                  if child.t == "Link" then
                    right_text = right_text .. "\\href{" .. child.target .. "}{" .. latex_stringify(child) .. "}"
                  else
                    right_text = right_text .. latex_stringify(child)
                  end
                end
                table.insert(parts, {side="right", text=right_text})
              end
            end
          end
        end
      end

      local left = ""
      local right = ""
      for _, p in ipairs(parts) do
        if p.side == "left" then left = p.text end
        if p.side == "right" then right = p.text end
      end

      return pandoc.RawBlock("latex", "\\noindent " .. left .. "\\hfill " .. right .. "\\par\\vspace{1pt}")
    else
      return el
    end
  end
end
