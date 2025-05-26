local api = vim.api
local M = {}

-- Configuración por defecto
local config = {
	width = 120,
	height = 20,
	border = "rounded",
}

-- Estado del popup
local state = {
	bufnr = nil,
	winid = nil,
	selected_idx = 1,
	items = {},
	filtered_items = {},
	search_text = "",
}

-- Crear los grupos de highlight
local function setup_highlights()
	vim.cmd([[
    highlight default link CoveragePopupBorder FloatBorder
    highlight default link CoveragePopupCursor PmenuSel
    highlight default link CoveragePopupTitle Title
    highlight default link CoveragePopupHeader Special
    highlight default link CoveragePopupMatch Search
    highlight default CoveragePopupGood guibg=#285028 guifg=#a8ffa8
    highlight default CoveragePopupMedium guibg=#524822 guifg=#ffe0a8
    highlight default CoveragePopupBad guibg=#502828 guifg=#ffa8a8
  ]])
end

-- Crear el buffer y la ventana
local function create_window()
	state.bufnr = api.nvim_create_buf(false, true)
	api.nvim_buf_set_option(state.bufnr, "bufhidden", "wipe")
	api.nvim_buf_set_option(state.bufnr, "filetype", "coverage-popup")

	local width = config.width
	local height = config.height
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local win_opts = {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = config.border,
		title = " Coverage Summary ",
		title_pos = "center",
	}
	state.winid = api.nvim_open_win(state.bufnr, true, win_opts)
	api.nvim_win_set_option(state.winid, "wrap", false)
	api.nvim_win_set_option(state.winid, "cursorline", true)
end

-- Formatear una línea de la tabla
local function format_line(item)
	-- Convertir todos los scores relevantes a números para la lógica de color
	local l_score = tonumber(item._coverage_score) or 0 -- Lines score
	local s_score = tonumber(item.statements_score or "0") or 0 -- Statements score
	local b_score = tonumber(item.branches_score or "0") or 0 -- Branches score
	local f_score = tonumber(item.functions_score or "0") or 0 -- Functions score

	local coverage_color
	if l_score == 100 and s_score == 100 and b_score == 100 and f_score == 100 then
		coverage_color = "%#CoveragePopupGood#" -- Verde
	elseif l_score >= 80 and s_score >= 80 and b_score >= 80 and f_score >= 80 then
		coverage_color = "%#CoveragePopupMedium#" -- Amarillo
	else
		coverage_color = "%#CoveragePopupBad#" -- Rojo
	end

	local max_file_length = 60
	local file_display = item.file
	if file_display == "__SUMMARY_PLACEHOLDER__" then
		file_display = "Total Coverage"
	else
		file_display = file_display:gsub(vim.fn.getcwd() .. "/", "") -- Usar vim.fn
		if #file_display > max_file_length then
			file_display = "..." .. file_display:sub(-max_file_length + 3)
		end
	end

	local function combine_uncovered(lines, funcs)
		if not lines or lines == "" then
			lines = nil
		end
		if not funcs or funcs == "" then
			funcs = nil
		end
		
		if lines and funcs then
			return lines .. ", " .. funcs
		elseif lines then
			return lines
		elseif funcs then
			return funcs
		else
			return "✓"
		end
	end

	local uncovered_text
	if item.file == "__SUMMARY_PLACEHOLDER__" then
		uncovered_text = "-" -- Para la línea de resumen
	else
		uncovered_text = combine_uncovered(item.uncovered_lines, item.uncovered_functions)
	end

	return {
		{ coverage_color },
		{
			string.format(
				" %-60s  %6.1f%%  %6.1f%%  %6.1f%%  %6.1f%%  %s",
				file_display,
				l_score, -- Usar l_score (Lines)
				s_score, -- Usar s_score (Statements)
				b_score, -- Usar b_score (Branches)
				f_score, -- Usar f_score (Functions)
				uncovered_text
			),
		},
	}
end

-- Actualizar el contenido del buffer
local function update_buffer()
	if not state.bufnr or not api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local ns_id = api.nvim_create_namespace("coverage_popup")
	api.nvim_buf_clear_namespace(state.bufnr, ns_id, 0, -1)

	local lines_to_display = {
		" Search: " .. state.search_text,
		string.format(" %-60s  %7s  %7s  %7s  %7s  %s", "File", "Lines", "Stmts", "Branch", "Funcs", "Uncovered"),
		" " .. string.rep("─", config.width - 4),
		"",
	}
	local highlights_to_apply = {}

	local filtered_without_summary = vim.tbl_filter(function(i)
		return i.file ~= "__SUMMARY_PLACEHOLDER__"
	end, state.filtered_items)

	for _, item_to_format in ipairs(filtered_without_summary) do
		local line_data = format_line(item_to_format)
		table.insert(lines_to_display, line_data[2][1])
		table.insert(highlights_to_apply, {
			line = #lines_to_display - 1,
			hl_group = line_data[1][1]:sub(3, -2),
			col_start = 0,
			col_end = -1,
		})
	end

	table.insert(lines_to_display, "")
	table.insert(lines_to_display, " " .. string.rep("─", config.width - 4))

	local summary_item = vim.tbl_filter(function(i)
		return i.file == "__SUMMARY_PLACEHOLDER__"
	end, state.filtered_items)[1]

	if summary_item then
		local line_data = format_line(summary_item)
		table.insert(lines_to_display, line_data[2][1])
		table.insert(highlights_to_apply, {
			line = #lines_to_display - 1,
			hl_group = line_data[1][1]:sub(3, -2),
			col_start = 0,
			col_end = -1,
		})
	end

	api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines_to_display)

	for _, hl in ipairs(highlights_to_apply) do
		api.nvim_buf_add_highlight(state.bufnr, ns_id, hl.hl_group, hl.line, hl.col_start, hl.col_end)
	end

	local cursor_line = #lines_to_display -- Por defecto al final si no hay items
	if #filtered_without_summary > 0 or summary_item then
		-- El índice 1 de la lista de ítems corresponde a la línea 5 en el buffer (después de Search, Header, Separador, Blank)
		-- selected_idx es 1-based para filtered_items
		-- Si selected_idx apunta al summary, necesitamos calcular su posición
		if
			state.filtered_items[state.selected_idx]
			and state.filtered_items[state.selected_idx].file == "__SUMMARY_PLACEHOLDER__"
		then
			cursor_line = #lines_to_display -- El summary es la última línea
		else
			cursor_line = 3 + state.selected_idx -- 3 líneas de cabecera + índice
		end
	end
	api.nvim_win_set_cursor(state.winid, { math.min(cursor_line, #lines_to_display), 0 })
end

-- Filtrar items basado en el texto de búsqueda
local function filter_items()
	if state.search_text == "" then
		state.filtered_items = state.items
		return
	end

	local search_term = state.search_text:lower()
	state.filtered_items = vim.tbl_filter(function(item)
		-- Asegurarse de que todos los campos de búsqueda sean strings
		local file_search = type(item.file) == "string" and item.file:lower() or ""
		local text_search = type(item.text) == "string" and item.text:lower() or "" -- 'text' podría no existir en todos los items
		local desc_search = type(item.desc) == "string" and item.desc:lower() or "" -- 'desc' podría no existir

		local combined_search_text = file_search .. " " .. text_search .. " " .. desc_search
		return combined_search_text:find(search_term, 1, true)
	end, state.items)
end

-- Configurar keymaps
local function setup_keymaps()
	local function map(key, fn_to_call)
		vim.keymap.set("n", key, fn_to_call, { buffer = state.bufnr, silent = true })
	end

	map("j", function()
		if #state.filtered_items == 0 then
			return
		end
		if state.selected_idx < #state.filtered_items then
			state.selected_idx = state.selected_idx + 1
			update_buffer()
		end
	end)

	map("k", function()
		if #state.filtered_items == 0 then
			return
		end
		if state.selected_idx > 1 then
			state.selected_idx = state.selected_idx - 1
			update_buffer()
		end
	end)

	map("q", function()
		api.nvim_win_close(state.winid, true)
	end)
	map("<Esc>", function()
		api.nvim_win_close(state.winid, true)
	end)

	map("<CR>", function()
		if #state.filtered_items == 0 then
			return
		end
		local item = state.filtered_items[state.selected_idx]
		if item and item.value and item.value ~= "__SUMMARY_DO_NOT_EDIT__" then
			api.nvim_win_close(state.winid, true)
			vim.cmd("edit " .. item.value) -- item.value debería ser full_edit_path
		end
	end)

	map("/", function()
		local search_items = {}
		for _, item in ipairs(state.items) do
			if item.file ~= "__SUMMARY_PLACEHOLDER__" then
				-- Extraer solo el nombre del archivo
				local filename = vim.fn.fnamemodify(item.file, ":t")
				table.insert(search_items, {
					name = filename,
					file = item.file,
					value = item.value,
					display = string.format("%s (%s)", filename, item.uncovered_lines or "✓")
				})
			end
		end

		vim.ui.select(
			search_items,
			{
				prompt = "Search coverage files:",
				format_item = function(item)
					return item.display
				end,
				kind = "coverage_files"
			},
			function(choice)
				if choice then
					if choice.value and choice.value ~= "__SUMMARY_DO_NOT_EDIT__" then
						api.nvim_win_close(state.winid, true)
						vim.cmd("edit " .. choice.value)
					end
				end
			end
		)
	end)
end

-- Función principal para mostrar el popup
function M.show(items_received)
	if not items_received or #items_received == 0 then
		vim.notify("No coverage items to display.", vim.log.levels.WARN)
		return
	end

	setup_highlights() -- Definir highlights primero

	-- Crear la ventana solo si no existe o no es válida
	if not state.winid or not api.nvim_win_is_valid(state.winid) then
		create_window()
	end

	state.items = items_received
	state.filtered_items = items_received -- Inicialmente, todos los ítems están filtrados
	state.selected_idx = 1
	state.search_text = ""

	setup_keymaps()
	update_buffer()
end

return M
