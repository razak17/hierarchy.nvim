local M = {}

M.reference_tree = {}
M.pending_items = 0
M.depth = 3
M.current_item = nil
M.refs_buf = nil
M.refs_ns = vim.api.nvim_create_namespace("function_references")
M.line_data = {}
M.expanded_nodes = {}

function M.safe_call(fn, ...)
	local status, result = pcall(fn, ...)
	if not status then
		vim.schedule(function()
			vim.notify("Function call error (handled): " .. tostring(result), vim.log.levels.DEBUG)
		end)
		return nil
	end
	return result
end

function M.process_item_calls(item, current_depth, parent_node)
	-- Stop if we've exceeded the maximum depth
	if current_depth > M.depth then
		M.pending_items = M.pending_items - 1
		if M.pending_items == 0 then
			M.display_custom_ui()
		end
		return
	end

	if not parent_node or type(parent_node) ~= "table" or not parent_node.references then
		vim.notify("Error: Invalid parent_node in process_item_calls", vim.log.levels.ERROR)
		M.pending_items = M.pending_items - 1
		if M.pending_items == 0 then
			M.display_custom_ui()
		end
		return
	end

	local params = {
		item = item
	}

	vim.lsp.buf_request(0, 'callHierarchy/outgoingCalls', params, function(err, result)
		local current_node = nil

		if current_depth > 1 then
			local is_exact_self_ref = (
				item.name == parent_node.name and
				item.uri == parent_node.uri and
				item.selectionRange.start.line == parent_node.selectionRange.start.line
			)

			if not is_exact_self_ref then
				current_node = parent_node.references[item.name]
				if not current_node then
					current_node = {
						name = item.name,
						uri = item.uri,
						range = item.range,
						selectionRange = item.selectionRange,
						references = {},
						display = item.name .. " [" .. vim.fn.fnamemodify(item.uri, ":t") .. ":" ..
							(item.selectionRange.start.line + 1) .. "]"
					}
					parent_node.references[item.name] = current_node
				end
			end
		end

		if not err and result and not vim.tbl_isempty(result) then
			for _, call in ipairs(result) do
				local target = call.to

				local next_parent = current_node or parent_node

				M.pending_items = M.pending_items + 1
				vim.defer_fn(function()
					M.process_item_calls(target, current_depth + 1, next_parent)
				end, 0)
			end
		end

		M.pending_items = M.pending_items - 1

		if M.pending_items == 0 then
			M.display_custom_ui()
		end
	end)
end

function M.build_reference_lines(node, lines, indent, expanded_nodes)
	indent = indent or 0
	lines = lines or {}
	expanded_nodes = expanded_nodes or {}

	local icon = "󰅲"

	if node.name:match("[Dd]ebug") then
		icon = "⭐"
	end

	local has_refs = node.references and next(node.references) ~= nil

	local prefix = string.rep("  ", indent)
	local expanded = expanded_nodes[node.name .. node.uri]

	if has_refs then
		prefix = prefix .. (expanded and "▼ " or "▶ ")
	else
		prefix = prefix .. "  "
	end

	local location = ""
	if node.uri then
		location = " [" .. vim.fn.fnamemodify(node.uri, ":t") .. ":" ..
			(node.selectionRange.start.line + 1) .. "]"
	end

	table.insert(lines, {
		text = prefix .. icon .. " " .. node.name .. location,
		node = node,
		indent = indent,
		has_refs = has_refs
	})

	if expanded and has_refs then
		for _, child in pairs(node.references) do
			M.build_reference_lines(child, lines, indent + 1, expanded_nodes)
		end
	end

	return lines
end

function M.display_custom_ui()
	if not M.reference_tree or vim.tbl_isempty(M.reference_tree.references) then
		vim.notify("No function references found", vim.log.levels.INFO)
		return
	end

	if not M.refs_buf or not vim.api.nvim_buf_is_valid(M.refs_buf) then
		M.refs_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(M.refs_buf, "FunctionReferences")

		local function safe_set_buf_option(buf, name, value)
			pcall(vim.api.nvim_buf_set_option, buf, name, value)
		end

		safe_set_buf_option(M.refs_buf, 'buftype', 'nofile')
		safe_set_buf_option(M.refs_buf, 'bufhidden', 'hide')
		safe_set_buf_option(M.refs_buf, 'swapfile', false)
		safe_set_buf_option(M.refs_buf, 'modifiable', false)
		safe_set_buf_option(M.refs_buf, 'filetype', 'FunctionReferences')

		vim.api.nvim_create_autocmd("BufWinLeave", {
			buffer = M.refs_buf,
			callback = function()
				if M.refs_buf and vim.api.nvim_buf_is_valid(M.refs_buf) then
					vim.api.nvim_buf_set_var(M.refs_buf, "expanded_nodes", {})
				end
			end,
			once = true
		})
	else
		vim.api.nvim_buf_set_option(M.refs_buf, 'modifiable', true)
		vim.api.nvim_buf_set_lines(M.refs_buf, 0, -1, false, {})
	end

	local expanded_nodes = {}
	if M.refs_buf and vim.api.nvim_buf_is_valid(M.refs_buf) then
		if vim.api.nvim_buf_is_loaded(M.refs_buf) then
			local ok, nodes = pcall(vim.api.nvim_buf_get_var, M.refs_buf, "expanded_nodes")
			if ok then
				expanded_nodes = nodes
			end
		end
	end

	expanded_nodes[M.reference_tree.name .. M.reference_tree.uri] = true

	local lines = M.build_reference_lines(M.reference_tree, {}, 0, expanded_nodes)

	local text_lines = {}
	for _, line in ipairs(lines) do
		table.insert(text_lines, line.text)
	end

	vim.api.nvim_buf_set_option(M.refs_buf, 'modifiable', true)
	vim.api.nvim_buf_set_lines(M.refs_buf, 0, -1, false, text_lines)
	vim.api.nvim_buf_set_option(M.refs_buf, 'modifiable', false)

	pcall(vim.api.nvim_buf_set_var, M.refs_buf, "line_data", lines)
	pcall(vim.api.nvim_buf_set_var, M.refs_buf, "expanded_nodes", expanded_nodes)

	M.line_data = lines
	M.expanded_nodes = expanded_nodes

	vim.api.nvim_buf_clear_namespace(M.refs_buf, M.refs_ns, 0, -1)
	for i, line in ipairs(lines) do
		local icon_start = line.text:find("󰅲") or line.text:find("⭐")
		if icon_start then
			vim.api.nvim_buf_add_highlight(M.refs_buf, M.refs_ns, "Special", i - 1, icon_start - 1, icon_start)
		end

		local name_start = line.text:find(line.node.name)
		if name_start then
			vim.api.nvim_buf_add_highlight(M.refs_buf, M.refs_ns, "Function", i - 1, name_start - 1,
				name_start + #line.node.name - 1)
		end

		local loc_start = line.text:find(" %[")
		if loc_start then
			vim.api.nvim_buf_add_highlight(M.refs_buf, M.refs_ns, "Comment", i - 1, loc_start - 1, -1)
		end
	end

	local keymap_opts = { noremap = true, silent = true }
	vim.api.nvim_buf_set_keymap(M.refs_buf, 'n', '<CR>',
		[[<cmd>lua require('hierarchy').toggle_reference_node()<CR>]],
		keymap_opts
	)

	vim.api.nvim_buf_set_keymap(M.refs_buf, 'n', '<2-LeftMouse>',
		[[<cmd>lua require('hierarchy').toggle_reference_node()<CR>]],
		keymap_opts
	)

	vim.api.nvim_buf_set_keymap(M.refs_buf, 'n', 'gd',
		[[<cmd>lua require('hierarchy').goto_function_definition()<CR>]],
		keymap_opts
	)

	local win_width = math.floor(vim.api.nvim_get_option("columns") * 0.4)

	local win_id = nil
	for _, wid in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(wid)
		if buf == M.refs_buf then
			win_id = wid
			break
		end
	end

	if not win_id then
		vim.cmd("vsplit")
		win_id = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win_id, M.refs_buf)
		vim.api.nvim_win_set_width(win_id, win_width)
	end

	local function safe_set_win_option(win, name, value)
		pcall(vim.api.nvim_win_set_option, win, name, value)
	end

	safe_set_win_option(win_id, 'wrap', false)
	safe_set_win_option(win_id, 'number', false)
	safe_set_win_option(win_id, 'relativenumber', false)
	safe_set_win_option(win_id, 'signcolumn', 'no')

	vim.api.nvim_buf_set_option(M.refs_buf, 'filetype', 'FunctionReferences')

	pcall(function()
		vim.cmd("setlocal statusline=REFERENCES:\\ " .. M.reference_tree.name:gsub("\\", "\\\\"):gsub(" ", "\\ "))
	end)

	vim.api.nvim_win_set_cursor(win_id, { 1, 0 })
end

function M.toggle_reference_node()
	local bufnr = vim.api.nvim_get_current_buf()
	if bufnr ~= M.refs_buf then return end

	local line_nr = vim.api.nvim_win_get_cursor(0)[1]

	local line_data
	local ok, buf_line_data = pcall(vim.api.nvim_buf_get_var, bufnr, "line_data")
	if ok and buf_line_data and buf_line_data[line_nr] then
		line_data = buf_line_data
	else
		line_data = M.line_data
	end

	if not line_data or not line_data[line_nr] then return end

	local item = line_data[line_nr]
	if not item.has_refs then
		M.goto_function_definition()
		return
	end

	local expanded_nodes
	local ok2, buf_expanded_nodes = pcall(vim.api.nvim_buf_get_var, bufnr, "expanded_nodes")
	if ok2 and buf_expanded_nodes then
		expanded_nodes = buf_expanded_nodes
	else
		expanded_nodes = M.expanded_nodes or {}
	end

	local node_id = item.node.name .. item.node.uri
	expanded_nodes[node_id] = not expanded_nodes[node_id]

	pcall(vim.api.nvim_buf_set_var, bufnr, "expanded_nodes", expanded_nodes)
	M.expanded_nodes = expanded_nodes

	M.redraw_references_buffer()

	vim.api.nvim_win_set_cursor(0, { line_nr, 0 })
end

function M.redraw_references_buffer()
	if not M.refs_buf or not vim.api.nvim_buf_is_valid(M.refs_buf) then return end

	local expanded_nodes
	local ok, buf_expanded_nodes = pcall(vim.api.nvim_buf_get_var, M.refs_buf, "expanded_nodes")
	if ok and buf_expanded_nodes then
		expanded_nodes = buf_expanded_nodes
	else
		expanded_nodes = M.expanded_nodes or {}
	end

	local lines = M.build_reference_lines(M.reference_tree, {}, 0, expanded_nodes)

	local text_lines = {}
	for _, line in ipairs(lines) do
		table.insert(text_lines, line.text)
	end

	vim.api.nvim_buf_set_option(M.refs_buf, 'modifiable', true)
	vim.api.nvim_buf_set_lines(M.refs_buf, 0, -1, false, text_lines)
	vim.api.nvim_buf_set_option(M.refs_buf, 'modifiable', false)

	pcall(vim.api.nvim_buf_set_var, M.refs_buf, "line_data", lines)
	M.line_data = lines

	vim.api.nvim_buf_clear_namespace(M.refs_buf, M.refs_ns, 0, -1)
	for i, line in ipairs(lines) do
		local icon_start = line.text:find("󰅲") or line.text:find("⭐")
		if icon_start then
			vim.api.nvim_buf_add_highlight(M.refs_buf, M.refs_ns, "Special", i - 1, icon_start - 1, icon_start)
		end

		local name_start = line.text:find(line.node.name)
		if name_start then
			vim.api.nvim_buf_add_highlight(M.refs_buf, M.refs_ns, "Function", i - 1, name_start - 1,
				name_start + #line.node.name - 1)
		end

		local loc_start = line.text:find(" %[")
		if loc_start then
			vim.api.nvim_buf_add_highlight(M.refs_buf, M.refs_ns, "Comment", i - 1, loc_start - 1, -1)
		end
	end
end

function M.goto_function_definition()
	local bufnr = vim.api.nvim_get_current_buf()
	if bufnr ~= M.refs_buf then return end

	local line_nr = vim.api.nvim_win_get_cursor(0)[1]

	local line_data
	local ok, buf_line_data = pcall(vim.api.nvim_buf_get_var, bufnr, "line_data")
	if ok and buf_line_data and buf_line_data[line_nr] then
		line_data = buf_line_data
	else
		line_data = M.line_data
	end

	if not line_data or not line_data[line_nr] then return end

	local item = line_data[line_nr]
	local node = item.node

	if node and node.uri and node.selectionRange then
		local filename = vim.uri_to_fname(node.uri)

		local jump_cmd = "edit +" .. (node.selectionRange.start.line + 1) .. " " .. vim.fn.fnameescape(filename)

		vim.cmd(jump_cmd)

		if node.selectionRange.start.character then
			vim.api.nvim_win_set_cursor(0, { node.selectionRange.start.line + 1, node.selectionRange.start.character })
		end
	end
end

function M.find_recursive_calls(depth, offset_encoding)
  offset_encoding = offset_encoding or "utf-16"
	M.reference_tree = {
		name = "",
		uri = "",
		range = {},
		selectionRange = {},
		references = {},
		display = ""
	}
	M.pending_items = 0
	M.depth = depth or 3

	local params = vim.lsp.util.make_position_params(0, offset_encoding)

	vim.lsp.buf_request(0, 'textDocument/prepareCallHierarchy', params, function(err, result)
		if err or not result or vim.tbl_isempty(result) then
			vim.notify("Could not prepare call hierarchy", vim.log.levels.ERROR)
			return
		end

		local item = result[1]
		M.current_item = item

		M.reference_tree = {
			name = item.name,
			uri = item.uri,
			range = item.range,
			selectionRange = item.selectionRange,
			references = {},
			display = item.name .. " [" .. vim.fn.fnamemodify(item.uri, ":t") .. ":" ..
				(item.selectionRange.start.line + 1) .. "]",
			expanded = false
		}

		M.pending_items = 1
		vim.defer_fn(function()
			M.process_item_calls(item, 1, M.reference_tree)
		end, 0)
	end)
end

function M.setup(opts)
	opts = opts or {}
	if opts.depth then
		M.depth = opts.depth
	end

	vim.api.nvim_create_user_command("FunctionReferences", function(cmd_opts)
		local depth = M.depth
		if cmd_opts.args and cmd_opts.args ~= "" then
			local args = vim.split(cmd_opts.args, " ")
			depth = tonumber(args[1]) or M.depth
		end

		local clients = vim.lsp.get_active_clients({ bufnr = 0 })
		if vim.tbl_isempty(clients) then
			vim.notify("No LSP clients attached to this buffer", vim.log.levels.ERROR)
			return
		end

		M.find_recursive_calls(depth)
	end, {
		nargs = "?",
		desc = "Find function references recursively. Usage: FunctionReferences [depth]"
	})
end

return M
