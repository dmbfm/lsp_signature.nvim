local vim = _G.vim or vim -- suppress warning, allow complete without lua-dev
local api = vim.api
local M = {}
local helper = require "lsp_signature_helper"
local match_parameter = helper.match_parameter
-- local check_closer_char = helper.check_closer_char

local manager = {
  insertChar = false, -- flag for InsertCharPre event, turn off imediately when performing completion
  insertLeave = true, -- flag for InsertLeave, prevent every completion if true
  changedTick = 0, -- handle changeTick
  confirmedCompletion = false, -- flag for manual confirmation of completion
  timer = nil
}

_LSP_SIG_CFG = {
  bind = true, -- This is mandatory, otherwise border config won't get registered.
  -- if you want to use lspsaga, please set it to false
  doc_lines = 10, -- how many lines to show in doc, set to 0 if you only want the signature
  max_height = 12, -- max height of signature floating_window
  max_width = 120, -- max_width of signature floating_window

  floating_window = true, -- show hint in a floating window
  floating_window_above_cur_line = true, -- try to place the floating above the current line
  floating_window_off_y = 1, -- adjust float windows y position. allow the pum to show a few lines
  close_timeout = 4000, -- close floating window after ms when laster parameter is entered
  fix_pos = function(signatures, _) -- second argument is the client
    return true -- can be expression like : return signatures[1].activeParameter >= 0 and signatures[1].parameters > 1
  end,
  -- also can be bool value fix floating_window position
  hint_enable = true, -- virtual hint
  hint_prefix = "🐼 ",
  hint_scheme = "String",
  hi_parameter = "LspSignatureActiveParameter",
  handler_opts = {border = "rounded"},
  padding = '', -- character to pad on left and right of signature
  use_lspsaga = false,
  always_trigger = false, -- sometime show signature on new line can be confusing, set it to false for #58
  -- set this to true if you the triggered_chars failed to work
  -- this will allow lsp server decide show signature or not
  auto_close_after = nil, -- autoclose signature after x sec, disabled if nil.
  debug = false,
  log_path = '', -- log dir when debug is no
  verbose = false, -- debug show code line number
  extra_trigger_chars = {}, -- Array of extra characters that will trigger signature completion, e.g., {"(", ","}
  -- decorator = {"`", "`"} -- set to nil if using guihua.lua
  zindex = 200,
  transparency = nil, -- disabled by default
  shadow_blend = 36, -- if you using shadow as border use this set the opacity
  shadow_guibg = 'Black', -- if you using shadow as border use this set the color e.g. 'Green' or '#121315'
  timer_interval = 200, -- default timer check interval
  toggle_key = nil, -- toggle signature on and off in insert mode,  e.g. '<M-x>'
  -- set this key also helps if you want see signature in newline
  check_3rd_handler = nil -- provide you own handler
}

local log = helper.log
function manager.init()
  manager.insertLeave = false
  manager.insertChar = false
  manager.confirmedCompletion = false
end

local function virtual_hint(hint, off_y)
  if hint == nil or hint == "" then
    return
  end
  local r = vim.api.nvim_win_get_cursor(0)
  local line = api.nvim_get_current_line()
  local line_to_cursor = line:sub(1, r[2])
  local cur_line = r[1] - 1 -- line number of current line, 0 based
  local show_at = cur_line - 1 -- show at above line
  local lines_above = vim.fn.winline() - 1
  local lines_below = vim.fn.winheight(0) - lines_above
  if lines_above > lines_below then
    show_at = cur_line + 1 -- same line
  end
  local pl
  local puvis = vim.fn.pumvisible() ~= 0
  if off_y ~= nil and off_y < 0 then -- floating win above first
    if puvis then
      show_at = cur_line -- pum, show at current line
    else
      show_at = cur_line + 1 -- show at below line
    end
  end

  if _LSP_SIG_CFG.floating_window == false then
    local prev_line, next_line
    if cur_line > 0 then
      prev_line = vim.api.nvim_buf_get_lines(0, cur_line - 1, cur_line, false)[1]
    end
    next_line = vim.api.nvim_buf_get_lines(0, cur_line + 1, cur_line + 2, false)[1]
    -- log(prev_line, next_line, r)
    if prev_line and vim.fn.strdisplaywidth(prev_line) < r[2] then
      show_at = cur_line - 1
      pl = prev_line
    elseif next_line and vim.fn.strdisplaywidth(next_line) < r[2] + 2 and not puvis then
      show_at = cur_line + 1
      pl = next_line
    else
      show_at = cur_line
    end
  end

  if cur_line == 0 then
    show_at = 0
  end
  -- get show at line
  if not pl then
    pl = vim.api.nvim_buf_get_lines(0, show_at, show_at + 1, false)[1]
  end
  if pl == nil then
    show_at = cur_line -- no lines below
  end

  -- log("virtual text: ", cur_line, show_at)
  pl = pl or ""
  local pad = ""
  local line_to_cursor_width = vim.fn.strdisplaywidth(line_to_cursor)
  local pl_width = vim.fn.strdisplaywidth(pl)
  if show_at ~= cur_line and line_to_cursor_width > pl_width + 1 then
    pad = string.rep(" ", line_to_cursor_width - pl_width)
  end
  _LSP_SIG_VT_NS = _LSP_SIG_VT_NS or vim.api.nvim_create_namespace("lsp_signature_vt")
  vim.api.nvim_buf_clear_namespace(0, _LSP_SIG_VT_NS, 0, -1)
  if r ~= nil then
    vim.api.nvim_buf_set_extmark(0, _LSP_SIG_VT_NS, show_at, 0, {
      virt_text = {{pad .. _LSP_SIG_CFG.hint_prefix .. hint, _LSP_SIG_CFG.hint_scheme}},
      virt_text_pos = "eol",
      hl_mode = "combine"
      -- hl_group = _LSP_SIG_CFG.hint_scheme
    })
  end
end

local close_events = {"CursorMoved", "CursorMovedI", "BufHidden", "InsertCharPre"}

-- ----------------------
-- --  signature help  --
-- ----------------------
-- Note: nvim 0.5.1/0.6.x   - signature_help(err, {result}, {ctx}, {config})
local signature_handler = helper.mk_handler(function(err, result, ctx, config)
  if err ~= nil then
    print(err)
    return
  end

  -- log("sig result", ctx, result, config)
  -- if config.check_client_handlers then
  --   -- this feature will be removed
  --   if helper.client_handler(err, result, ctx, config) then
  --     return
  --   end
  -- end
  local client_id = ctx.client_id
  local bufnr = ctx.bufnr
  if not (result and result.signatures and result.signatures[1]) then
    -- only close if this client opened the signature
    if _LSP_SIG_CFG.client_id == client_id then
      helper.cleanup_async(true, 0.1)

      -- need to close floating window and virtual text (if they are active)
    end

    return
  end

  if #result.signatures > 1 and (result.activeSignature or 0) > 0 then
    local sig_num = math.min(_LSP_SIG_CFG.max_height, #result.signatures - result.activeSignature)
    result.signatures = {unpack(result.signatures, result.activeSignature + 1, sig_num)}
    result.activeSignature = 0 -- reset
  end

  log("sig result", ctx, result, config)
  _LSP_SIG_CFG.signature_result = result

  local activeSignature = result.activeSignature or 0
  activeSignature = activeSignature + 1
  if activeSignature > #result.signatures then
    -- this is a upstream bug of metals
    activeSignature = #result.signatures
  end

  local actSig = result.signatures[activeSignature]

  if actSig ~= nil then
    actSig.label = string.gsub(actSig.label, '[\n\r\t]', " ")
    if actSig.parameters then
      for i = 1, #actSig.parameters do
        if type(actSig.parameters[i].label) == "string" then
          actSig.parameters[i].label = string.gsub(actSig.parameters[i].label, '[\n\r\t]', " ")
        end
      end
    end
  end

  local _, hint, s, l = match_parameter(result, config)
  local force_redraw = false
  if #result.signatures > 1 then
    force_redraw = true
    for i = #result.signatures, 1, -1 do
      local sig = result.signatures[i]
      -- hack for lua
      local actPar = sig.activeParameter or result.activeParameter or 0
      if actPar + 1 > #(sig.parameters or {}) then
        log("hack for lua")
        table.remove(result.signatures, i)
        if i <= activeSignature and activeSignature > 1 then
          activeSignature = activeSignature - 1
        end
      end
    end
  end

  if _LSP_SIG_CFG.doc_lines == 0 then -- doc disabled
    helper.remove_doc(result)
  end

  local lines = {}
  local off_y = 0
  if _LSP_SIG_CFG.floating_window == true or not config.trigger_from_lsp_sig then
    local ft = vim.api.nvim_buf_get_option(bufnr, "ft")
    lines = vim.lsp.util.convert_signature_help_to_markdown_lines(result, ft)

    if lines == nil or type(lines) ~= "table" then
      log("incorrect result", result)
      return
    end

    lines = vim.lsp.util.trim_empty_lines(lines)
    -- offset used for multiple signatures

    log("md lines trim", lines)
    local offset = 2
    local num_sigs = #result.signatures
    if #result.signatures > 1 then
      if string.find(lines[1], [[```]]) then -- markdown format start with ```, insert pos need after that
        log("line1 is markdown reset offset to 3")
        offset = 3
      end
      log("before insert", lines)
      for index, sig in ipairs(result.signatures) do
        if index ~= activeSignature then
          table.insert(lines, offset, sig.label)
          offset = offset + 1
        end
      end
    end

    -- log("md lines", lines)
    local label = result.signatures[1].label
    if #result.signatures > 1 then
      label = result.signatures[activeSignature].label
    end

    log("label:", label, result.activeSignature, activeSignature, result.activeParameter,
        result.signatures[activeSignature])

    -- truncate empty document it
    if result.signatures[activeSignature].documentation and result.signatures[activeSignature].documentation.kind
        == "markdown" and result.signatures[activeSignature].documentation.value == "```text\n\n```" then
      result.signatures[activeSignature].documentation = nil
      lines = vim.lsp.util.convert_signature_help_to_markdown_lines(result, ft)

      log("md lines remove empty", lines)
    end

    local pos = api.nvim_win_get_cursor(0)
    local line = api.nvim_get_current_line()
    local line_to_cursor = line:sub(1, pos[2])

    local woff = 1
    if config.triggered_chars and vim.tbl_contains(config.triggered_chars, '(') then
      woff = helper.cal_woff(line_to_cursor, label)
    end

    -- total lines allowed
    lines = helper.truncate_doc(lines, num_sigs)

    -- log(lines)
    if vim.tbl_isempty(lines) then
      log("WARN: signature is empty")
      return
    end
    local syntax = vim.lsp.util.try_trim_markdown_code_blocks(lines)

    if config.trigger_from_lsp_sig == true and _LSP_SIG_CFG.preview == "guihua" then
      -- This is a TODO
      error("guihua text view not supported yet")
    end
    helper.update_config(config)
    config.offset_x = woff

    if type(_LSP_SIG_CFG._fix_pos) == "function" then
      local client = vim.lsp.get_client_by_id(client_id)
      _LSP_SIG_CFG._fix_pos = _LSP_SIG_CFG._fix_pos(result, client)
    else
      _LSP_SIG_CFG._fix_pos = _LSP_SIG_CFG._fix_pos or true
    end

    config.close_events = {'BufHidden'} -- , 'InsertLeavePre'}
    if not _LSP_SIG_CFG._fix_pos then
      config.close_events = close_events
    end
    if not config.trigger_from_lsp_sig then
      config.close_events = close_events
    end
    if force_redraw and _LSP_SIG_CFG._fix_pos == false then
      config.close_events = close_events
    end
    if result.signatures[activeSignature].parameters == nil or #result.signatures[activeSignature].parameters == 0 then
      -- auto close when fix_pos is false
      if _LSP_SIG_CFG._fix_pos == false then
        config.close_events = close_events
      end
    end
    config.zindex = _LSP_SIG_CFG.zindex
    -- fix pos case
    log('win config', config)
    local new_line = helper.is_new_line()

    if _LSP_SIG_CFG.padding ~= "" then
      for lineIndex = 1, #lines do
        lines[lineIndex] = _LSP_SIG_CFG.padding .. lines[lineIndex] .. _LSP_SIG_CFG.padding
      end
      config.offset_x = config.offset_x - #_LSP_SIG_CFG.padding
    end

    local display_opts = {}
    display_opts, off_y = helper.cal_pos(lines, config)

    config.offset_y = off_y
    config.focusable = true -- allow focus
    config.max_height = display_opts.height

    -- try not to overlap with pum autocomplete menu
    if config.check_pumvisible and vim.fn.pumvisible() ~= 0
        and ((display_opts.anchor == 'NW' or display_opts.anchor == 'NE') and off_y == 0) and _LSP_SIG_CFG.zindex < 50 then
      log("pumvisible no need to show off_y", off_y)
      return
    end

    -- log("floating opt", config, display_opts)
    if _LSP_SIG_CFG._fix_pos and _LSP_SIG_CFG.bufnr and _LSP_SIG_CFG.winnr then
      if api.nvim_win_is_valid(_LSP_SIG_CFG.winnr) and _LSP_SIG_CFG.label == label and not new_line then
        helper.cleanup(false) -- cleanup extmark
      else
        -- vim.api.nvim_win_close(_LSP_SIG_CFG.winnr, true)
        _LSP_SIG_CFG.bufnr, _LSP_SIG_CFG.winnr = vim.lsp.util.open_floating_preview(lines, syntax, config)

        log("sig_cfg bufnr, winnr not valid recreate", _LSP_SIG_CFG.bufnr, _LSP_SIG_CFG.winnr)
        _LSP_SIG_CFG.label = label
        _LSP_SIG_CFG.client_id = client_id
      end
    else
      _LSP_SIG_CFG.bufnr, _LSP_SIG_CFG.winnr = vim.lsp.util.open_floating_preview(lines, syntax, config)
      _LSP_SIG_CFG.label = label
      _LSP_SIG_CFG.client_id = client_id

      log("sig_cfg new bufnr, winnr ", _LSP_SIG_CFG.bufnr, _LSP_SIG_CFG.winnr)
    end

    if _LSP_SIG_CFG.transparency and _LSP_SIG_CFG.transparency > 1 and _LSP_SIG_CFG.transparency < 100 then
      vim.api.nvim_win_set_option(_LSP_SIG_CFG.winnr, "winblend", _LSP_SIG_CFG.transparency)
    end
    local sig = result.signatures
    -- if it is last parameter, close windows after cursor moved
    if sig and sig[activeSignature].parameters == nil or result.activeParameter == nil or result.activeParameter + 1
        == #sig[activeSignature].parameters then
      -- log("last para", close_events)
      if _LSP_SIG_CFG._fix_pos == false then
        vim.lsp.util.close_preview_autocmd(close_events, _LSP_SIG_CFG.winnr)
        -- elseif _LSP_SIG_CFG._fix_pos then
        --   vim.lsp.util.close_preview_autocmd(close_events_au, _LSP_SIG_CFG.winnr)
      end
      if _LSP_SIG_CFG.auto_close_after then
        helper.cleanup_async(true, _LSP_SIG_CFG.auto_close_after)
      end
    end
    helper.highlight_parameter(s, l)
  end

  if _LSP_SIG_CFG.hint_enable == true and config.trigger_from_lsp_sig then
    virtual_hint(hint, off_y)
  end
  return lines, s, l
end)

local signature = function()
  local pos = api.nvim_win_get_cursor(0)
  local line = api.nvim_get_current_line()
  local line_to_cursor = line:sub(1, pos[2])
  local clients = vim.lsp.buf_get_clients(0)
  if clients == nil or clients == {} then
    return
  end

  local signature_cap, triggered, trigger_position, trigger_chars = helper.check_lsp_cap(clients, line_to_cursor)

  if signature_cap == false then
    log("signature capabilities not enabled")
    return
  end

  if triggered then
    -- overwrite signature help here to disable "no signature help" message
    local params = vim.lsp.util.make_position_params()
    params.position.character = trigger_position
    -- Try using the already binded one, otherwise use it without custom config.
    -- LuaFormatter off
    vim.lsp.buf_request(0, "textDocument/signatureHelp", params,
                        vim.lsp.with(signature_handler, {
                          check_pumvisible = true,
                          trigger_from_lsp_sig = true,
                          line_to_cursor = line_to_cursor:sub(1, trigger_position),
                          border = _LSP_SIG_CFG.handler_opts.border,
                          triggered_chars = trigger_chars
                        }))
    -- LuaFormatter on
  else
    -- check if we should close the signature
    -- print('should close')
    if _LSP_SIG_CFG.winnr and _LSP_SIG_CFG.winnr > 0 then
      -- if check_closer_char(line_to_cursor, triggered_chars) then
      if vim.api.nvim_win_is_valid(_LSP_SIG_CFG.winnr) then
        vim.api.nvim_win_close(_LSP_SIG_CFG.winnr, true)
      end
      _LSP_SIG_CFG.winnr = nil
      _LSP_SIG_CFG.bufnr = nil
      _LSP_SIG_CFG.startx = nil
      -- end
    end

    -- check should we close virtual hint
    if _LSP_SIG_CFG.signature_result and _LSP_SIG_CFG.signature_result.signatures ~= nil then
      local sig = _LSP_SIG_CFG.signature_result.signatures
      local actSig = _LSP_SIG_CFG.signature_result.activeSignature or 0
      local actPar = _LSP_SIG_CFG.signature_result.activeParameter or 0
      actSig, actPar = actSig + 1, actPar + 1
      if sig[actSig] ~= nil and sig[actSig].parameters ~= nil and #sig[actSig].parameters == actPar then
        M.on_CompleteDone()
      end
      _LSP_SIG_CFG.signature_result = nil
    end
  end

end

M.signature = signature

function M.on_InsertCharPre()
  manager.insertChar = true
end

function M.on_InsertLeave()
  local mode = vim.api.nvim_get_mode().mode
  if mode == 'niI' then
    log('mode: ', vim.api.nvim_get_mode().mode)
    return
  end

  manager.insertLeave = true
  if manager.timer then
    manager.timer:stop()
    manager.timer:close()
    manager.timer = nil
  end
  log('Insert leave cleanup')
  helper.cleanup_async(true, 0.3, true) -- defer close after 0.3s
end

local start_watch_changes_timer = function()
  if not manager.timer then
    manager.changedTick = 0
    local interval = _LSP_SIG_CFG.timer_interval or 200
    manager.timer = vim.loop.new_timer()
    manager.timer:start(100, interval, vim.schedule_wrap(function()
      local l_changedTick = api.nvim_buf_get_changedtick(0)
      if l_changedTick ~= manager.changedTick then
        manager.changedTick = l_changedTick
        signature()
      end
    end))
  end
end

function M.on_InsertEnter()
  -- log("insert enter")
  -- show signature immediately upon entering insert mode
  if manager.insertLeave == true then
    start_watch_changes_timer()
  end
  manager.init()
end

-- handle completion confirmation and dismiss hover popup
-- Note: this function may not work, depends on if complete plugin add parents or not
function M.on_CompleteDone()
  -- need auto brackets to make things work
  -- signature()
  -- cleanup virtual hint
  local m = vim.api.nvim_get_mode().mode
  vim.api.nvim_buf_clear_namespace(0, _LSP_SIG_VT_NS, 0, -1)
  if m == 'i' or m == 's' or m == 'v' then
    log("completedone ", m, "enable signature ?")
  end

  log('Insert leave cleanup', m)
end

M.deprecated = function(cfg)
  if cfg.trigger_on_new_line ~= nil or cfg.trigger_on_nomatch ~= nil then
    print('trigger_on_new_line and trigger_on_nomatch deprecated, using always_trigger instead')
  end

  if cfg.use_lspsaga or cfg.check_3rd_handler ~= nil then
    print('lspsaga signature and 3rd handler deprecated')
  end
  if cfg.floating_window_above_first ~= nil then
    print('use floating_window_above_cur_line instead')
  end
  if cfg.decorator then
    print('decorator deprecated, use hi_parameter instead')
  end
end

M.on_attach = function(cfg, bufnr)
  bufnr = bufnr or 0

  api.nvim_command("augroup Signature")
  api.nvim_command("autocmd! * <buffer>")
  api.nvim_command("autocmd InsertEnter <buffer> lua require'lsp_signature'.on_InsertEnter()")
  api.nvim_command("autocmd InsertLeave <buffer> lua require'lsp_signature'.on_InsertLeave()")
  api.nvim_command("autocmd InsertCharPre <buffer> lua require'lsp_signature'.on_InsertCharPre()")
  api.nvim_command("autocmd CompleteDone <buffer> lua require'lsp_signature'.on_CompleteDone()")

  api.nvim_command("autocmd CursorHold,CursorHoldI <buffer> lua require'lsp_signature'.check_signature_should_close()")
  api.nvim_command("augroup end")

  if type(cfg) == "table" then
    _LSP_SIG_CFG = vim.tbl_extend("keep", cfg, _LSP_SIG_CFG)
    log(_LSP_SIG_CFG)
  end

  vim.cmd([[hi default FloatBorder guifg = #777777]])
  if _LSP_SIG_CFG.bind then
    vim.lsp.handlers["textDocument/signatureHelp"] = vim.lsp.with(signature_handler, _LSP_SIG_CFG.handler_opts)
  end

  local shadow_cmd = string.format("hi default FloatShadow blend=%i guibg=%s", _LSP_SIG_CFG.shadow_blend,
                                   _LSP_SIG_CFG.shadow_guibg)
  vim.cmd(shadow_cmd)

  shadow_cmd = string.format("hi default FloatShadowThrough blend=%i guibg=%s", _LSP_SIG_CFG.shadow_blend + 20,
                             _LSP_SIG_CFG.shadow_guibg)
  vim.cmd(shadow_cmd)

  if _LSP_SIG_CFG.toggle_key then
    vim.api.nvim_buf_set_keymap(bufnr, 'i', _LSP_SIG_CFG.toggle_key,
                                [[<cmd>lua require('lsp_signature').toggle_float_win()<CR>]],
                                {silent = true, noremap = true})
  end
  _LSP_SIG_VT_NS = api.nvim_create_namespace("lsp_signature_vt")

end

local signature_should_close_handler = helper.mk_handler(function(err, result, ctx, _)
  if err ~= nil then
    print(err)
    helper.cleanup_async(true, 0.01)
    return
  end

  log("sig cleanup", result, ctx)
  local client_id = ctx.client_id
  if not (result and result.signatures and result.signatures[1]) then
    -- only close if this client opened the signature
    if _LSP_SIG_CFG.client_id == client_id then
      helper.cleanup_async(true, 0.01)
    end
    return
  end

end)

M.check_signature_should_close = function()
  if _LSP_SIG_CFG.winnr and _LSP_SIG_CFG.winnr > 0 and vim.api.nvim_win_is_valid(_LSP_SIG_CFG.winnr) then
    local params = vim.lsp.util.make_position_params()
    local pos = api.nvim_win_get_cursor(0)
    local line = api.nvim_get_current_line()
    local line_to_cursor = line:sub(1, pos[2])
    -- Try using the already binded one, otherwise use it without custom config.
    -- LuaFormatter off
  vim.lsp.buf_request(0, "textDocument/signatureHelp", params,
                      vim.lsp.with(signature_should_close_handler, {
                        check_pumvisible = true,
                        trigger_from_lsp_sig = true,
                        line_to_cursor = line_to_cursor,
                        border = _LSP_SIG_CFG.handler_opts.border,
                      }))

  end

  -- LuaFormatter on

end

M.toggle_float_win = function()
  if _LSP_SIG_CFG.winnr and _LSP_SIG_CFG.winnr > 0 and vim.api.nvim_win_is_valid(_LSP_SIG_CFG.winnr) then
    vim.api.nvim_win_close(_LSP_SIG_CFG.winnr, true)
    _LSP_SIG_CFG.winnr = nil
    _LSP_SIG_CFG.bufnr = nil
    if _LSP_SIG_VT_NS then
      vim.api.nvim_buf_clear_namespace(0, _LSP_SIG_VT_NS, 0, -1)
    end
    return
  end

  local params = vim.lsp.util.make_position_params()
  local pos = api.nvim_win_get_cursor(0)
  local line = api.nvim_get_current_line()
  local line_to_cursor = line:sub(1, pos[2])
  -- Try using the already binded one, otherwise use it without custom config.
  -- LuaFormatter off
  vim.lsp.buf_request(0, "textDocument/signatureHelp", params,
                      vim.lsp.with(signature_handler, {
                        check_pumvisible = true,
                        trigger_from_lsp_sig = true,
                        line_to_cursor = line_to_cursor,
                        border = _LSP_SIG_CFG.handler_opts.border,
                      }))
  -- LuaFormatter on

end

M.signature_handler = signature_handler
-- setup function enable the signature and attach it to client
-- call it before startup lsp client

M.setup = function(cfg)
  cfg = cfg or {}
  M.deprecated(cfg)
  log("user cfg:", cfg)
  local _start_client = vim.lsp.start_client
  _LSP_SIG_VT_NS = api.nvim_create_namespace("lsp_signature_vt")
  vim.lsp.start_client = function(lsp_config)
    if lsp_config.on_attach == nil then
      lsp_config.on_attach = function(client, bufnr)
        M.on_attach(cfg, bufnr)
      end
    else
      local _on_attach = lsp_config.on_attach
      lsp_config.on_attach = function(client, bufnr)
        M.on_attach(cfg, bufnr)
        _on_attach(client, bufnr)
      end
    end
    return _start_client(lsp_config)
  end

  -- default if not defined
  vim.cmd([[hi default link LspSignatureActiveParameter Search]])
end

return M
