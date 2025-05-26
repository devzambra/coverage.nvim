local M = {}

-- Estado global para rastrear si los highlights están activos
M.highlights_active = true

-- Función para cargar o crear la configuración
local function load_config()
	local config_path = vim.fn.stdpath("data") .. "/coverage_config.json"
	local f = io.open(config_path, "r")
	if f then
		local content = f:read("*all")
		f:close()
		local ok, config = pcall(vim.fn.json_decode, content)
		if ok and config then
			M.highlights_active = config.highlights_active
		end
	end
end

-- Función para guardar la configuración
local function save_config()
	local config_path = vim.fn.stdpath("data") .. "/coverage_config.json"
	local config = { highlights_active = M.highlights_active }
	local f = io.open(config_path, "w")
	if f then
		f:write(vim.fn.json_encode(config))
		f:close()
	end
end

-- Cargar configuración al iniciar
load_config()

-- Encuentra la raíz del proyecto
local function find_project_root()
	local cwd = vim.fn.getcwd()
	local markers = { "package.json", ".git", "jest.config.js", "tsconfig.json" }

	local function exists(path)
		return vim.loop.fs_stat(path) ~= nil
	end

	local dir = cwd
	while dir ~= "/" do
		for _, marker in ipairs(markers) do
			if exists(dir .. "/" .. marker) then
				return dir
			end
		end
		dir = vim.fn.fnamemodify(dir, ":h")
	end
	return cwd
end

-- Define colores de resaltado
local function define_highlight_groups()
	vim.cmd("highlight! CoverageUncovered guibg=#3c0000 guifg=#ffffff")
	vim.cmd("highlight! CoveragePartial   guibg=#3c3c00 guifg=#ffffff")
	vim.cmd("highlight! CoverageCovered   guibg=#003c00 guifg=#ffffff")
end

-- Parsea lcov y devuelve tablas de cobertura por línea y ramas por línea
local function parse_lcov(lcov_path, target_rel_path)
	local file = io.open(lcov_path, "r")
	if not file then
		vim.notify("No se encontró " .. lcov_path, vim.log.levels.ERROR)
		return nil
	end

	local line_hits = {}
	local branches = {}
	local current_file = nil

	for line in file:lines() do
		if line:match("^SF:") then
			current_file = line:sub(4)
		elseif current_file == target_rel_path then
			if line:match("^DA:") then
				local line_num, hits = line:match("^DA:(%d+),(%d+)")
				if line_num and hits then
					line_hits[tonumber(line_num)] = tonumber(hits)
				end
			elseif line:match("^BRDA:") then
				local line_num, _, _, taken = line:match("^BRDA:(%d+),%d+,%d+,([-%d]+)")
				if line_num then
					local num = tonumber(line_num)
					branches[num] = branches[num] or { total = 0, not_taken = 0 }

					branches[num].total = branches[num].total + 1
					if taken == "-" or tonumber(taken) == 0 then
						branches[num].not_taken = branches[num].not_taken + 1
					end
				end
			end
		end
	end

	file:close()

	return {
		lines = line_hits,
		branches = branches,
	}
end

-- Aplica los highlights si están activos
function M.apply_coverage_highlights()
	if not M.highlights_active then
		-- Si los highlights están desactivados, limpiar los que puedan existir
		local ns_id = vim.api.nvim_create_namespace("coverage_highlight")
		vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
		return
	end

	define_highlight_groups()

	local project_root = find_project_root()
	local lcov_file = project_root .. "/coverage/lcov.info"
	local abs_file = vim.fn.expand("%:p")
	local rel_file = abs_file:gsub(project_root .. "/", "")

	local data = parse_lcov(lcov_file, rel_file)
	if not data or not data.lines then
		vim.notify("No hay datos de cobertura para " .. rel_file, vim.log.levels.WARN)
		return
	end

	local ns_id = vim.api.nvim_create_namespace("coverage_highlight")
	vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)

	local total_lines = vim.api.nvim_buf_line_count(0)

	for line_num, hits in pairs(data.lines) do
		if line_num <= total_lines then
			local hl_group

			if hits == 0 then
				hl_group = "CoverageUncovered"
			elseif data.branches[line_num] and data.branches[line_num].not_taken > 0 then
				hl_group = "CoveragePartial"
			else
				hl_group = "CoverageCovered"
			end

			vim.api.nvim_buf_set_extmark(0, ns_id, line_num - 1, 0, {
				hl_group = hl_group,
				end_line = line_num,
				hl_eol = true,
			})
		end
	end
end

-- Función para alternar la visibilidad de los highlights
function M.toggle_coverage_highlights()
	M.highlights_active = not M.highlights_active
	save_config()

	if M.highlights_active then
		M.apply_coverage_highlights()
		vim.notify("Highlights de cobertura activados", vim.log.levels.INFO)
	else
		local ns_id = vim.api.nvim_create_namespace("coverage_highlight")
		vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
		vim.notify("Highlights de cobertura desactivados", vim.log.levels.INFO)
	end
end

-- Función para mostrar el estado actual de los highlights
function M.show_highlights_status()
	local status = M.highlights_active and "activados" or "desactivados"
	vim.notify("Los highlights de cobertura están " .. status, vim.log.levels.INFO)
end

function M.show_coverage_summary()
	-- Ayudante para asegurar que un valor es una cadena, por defecto cadena vacía si es nil
	local function ensure_string(val)
		if val == nil then
			return " "
		end
		if type(val) == "string" and val ~= "" then
			return val -- Devuelve el string original si ya es un string válido y no vacío
		end
		local str_val = tostring(val)
		if str_val == "" then
			return " "
		end
		return str_val
	end

	local project_root = find_project_root()
	-- Asegurar que project_root no tiene una barra al final para consistencia
	project_root = project_root:gsub("[/\\]$", "")

	local lcov_file = project_root .. "/coverage/lcov.info"
	local file_handle = io.open(lcov_file, "r")

	if not file_handle then
		vim.notify("No se encontró " .. lcov_file, vim.log.levels.ERROR)
		return
	end

	local files_data = {}
	local current_file_path = nil

	for line in file_handle:lines() do
		if line:match("^SF:") then
			current_file_path = line:sub(4)
			files_data[current_file_path] = files_data[current_file_path]
				or {
					statements = { total = 0, covered = 0 },
					branches = { total = 0, covered = 0 },
					functions = { total = 0, covered = 0 },
					lines = { total = 0, covered = 0 },
				}
		elseif current_file_path then -- Procesar solo si current_file_path está definido
			if line:match("^DA:") then
				local line_num_str, hits_str = line:match("^DA:(%d+),(%d+)")
				if line_num_str and hits_str then
					local line_num = tonumber(line_num_str)
					local hits = tonumber(hits_str)

					files_data[current_file_path].lines.total = files_data[current_file_path].lines.total + 1
					files_data[current_file_path].statements.total = files_data[current_file_path].statements.total + 1 -- Asumiendo que cada línea DA es un statement
					if hits > 0 then
						files_data[current_file_path].lines.covered = files_data[current_file_path].lines.covered + 1
						files_data[current_file_path].statements.covered = files_data[current_file_path].statements.covered
							+ 1
					end
					-- Poblar también la tabla detallada de line_hits
					if not files_data[current_file_path].line_hits then
						files_data[current_file_path].line_hits = {}
					end
					files_data[current_file_path].line_hits[line_num] = hits
				end
			elseif line:match("^BRDA:") then
				local _, _, _, taken_str = line:match("^BRDA:(%d+),(%d+),(%d+),([%d%-]+)")
				if taken_str then -- Asegurarse de que el grupo 'taken' fue capturado
					files_data[current_file_path].branches.total = files_data[current_file_path].branches.total + 1
					if taken_str ~= "-" then
						local taken_num = tonumber(taken_str)
						if taken_num then -- Conversión a número exitosa
							if taken_num > 0 then
								files_data[current_file_path].branches.covered = files_data[current_file_path].branches.covered
									+ 1
							end
						-- Si taken_num es 0, no se cuenta como cubierta, lo cual es correcto.
						else
							-- taken_str no es "-" y no se pudo convertir a número. Esto es inesperado.
							vim.notify(
								string.format(
									"Advertencia LCOV (BRDA): Valor 'taken' inesperado '%s' en archivo %s. Línea original: %s",
									taken_str,
									current_file_path,
									line
								),
								vim.log.levels.WARN
							)
						end
					end
				-- Si taken_str es "-", no se cuenta como cubierta, lo cual es correcto.
				else
					-- El patrón BRDA general coincidió, pero no se pudo capturar el valor 'taken'.
					-- Esto sería muy inusual con el patrón actual ([%d%-]+) a menos que la línea BRDA esté muy malformada.
					vim.notify(
						string.format(
							"Advertencia LCOV (BRDA): No se pudo capturar el valor 'taken' en archivo %s. Línea original: %s",
							current_file_path,
							line
						),
						vim.log.levels.WARN
					)
				end
			elseif line:match("^FNDA:") then
				local hits_str = line:match("^FNDA:(%d+),.*")
				if hits_str then
					local hits = tonumber(hits_str)
					files_data[current_file_path].functions.total = files_data[current_file_path].functions.total + 1
					if hits and hits > 0 then
						files_data[current_file_path].functions.covered = files_data[current_file_path].functions.covered
							+ 1
					end
				end
			end
		end
	end
	file_handle:close()

	local function pct(covered, total)
		if total == 0 then
			return 0
		end
		return (covered / total) * 100
	end

	local total_coverage_stats = {
		statements = { covered = 0, total = 0 },
		branches = { covered = 0, total = 0 },
		functions = { covered = 0, total = 0 },
		lines = { covered = 0, total = 0 },
	}
	local items = {}

	for file_path, stats in pairs(files_data) do
		if file_path and type(file_path) == "string" then -- file_path es la clave, ya es string
			local p_lines = (stats.lines.total == 0) and 100.0 or pct(stats.lines.covered, stats.lines.total)
			local p_statements = (stats.statements.total == 0) and 100.0
				or pct(stats.statements.covered, stats.statements.total)
			local p_branches = (stats.branches.total == 0) and 100.0
				or pct(stats.branches.covered, stats.branches.total)
			local p_functions = (stats.functions.total == 0) and 100.0
				or pct(stats.functions.covered, stats.functions.total)

			local full_edit_path = project_root .. "/" .. file_path

			local compact_summary_str =
				string.format("L:%.1f%% S:%.1f%% B:%.1f%% F:%.1f%%", p_lines, p_statements, p_branches, p_functions)

			local detailed_description_str = string.format(
				"Lines: %.1f%% (%d/%d, %d unc.) | Stmts: %.1f%% (%d/%d, %d unc.) | Branches: %.1f%% (%d/%d, %d unc.) | Funcs: %.1f%% (%d/%d, %d unc.)",
				p_lines,
				stats.lines.covered,
				stats.lines.total,
				stats.lines.total - stats.lines.covered,
				p_statements,
				stats.statements.covered,
				stats.statements.total,
				stats.statements.total - stats.statements.covered,
				p_branches,
				stats.branches.covered,
				stats.branches.total,
				stats.branches.total - stats.branches.covered,
				p_functions,
				stats.functions.covered,
				stats.functions.total,
				stats.functions.total - stats.functions.covered
			)

			-- Preparar información para la búsqueda
			local s_file_path = ensure_string(file_path)
			local s_compact_summary = ensure_string(compact_summary_str)
			local s_detailed_description = ensure_string(detailed_description_str)
			local s_coverage_score = string.format("%.2f", p_lines)

			-- Construir texto de búsqueda optimizado para Snacks.picker
			local search_text = table.concat({
				s_file_path:lower(), -- ruta del archivo en minúsculas
				" ",
				s_compact_summary:lower(), -- resumen compacto en minúsculas
				" ",
				s_detailed_description:lower(), -- descripción detallada en minúsculas
				string.format(" coverage %d", math.floor(p_lines)), -- porcentaje de cobertura redondeado
				string.format(" lines %d", math.floor(p_lines)), -- líneas cubiertas
				string.format(" branches %d", math.floor(p_branches)), -- ramas cubiertas
				string.format(" functions %d", math.floor(p_functions)), -- funciones cubiertas
			})

			-- Preparar las líneas no cubiertas
			local uncovered_lines_numbers = {} -- Inicializar como tabla vacía PARA ESTE ARCHIVO
			if stats.line_hits and type(stats.line_hits) == "table" then -- Iterar sobre stats.line_hits
				for line_num, hits in pairs(stats.line_hits) do
					if hits == 0 then
						table.insert(uncovered_lines_numbers, tonumber(line_num))
					end
				end
			end

			-- Ordenar las líneas numéricamente
			table.sort(uncovered_lines_numbers)

			-- Formatear las líneas no cubiertas en rangos
			local uncovered_ranges = {}
			if #uncovered_lines_numbers > 0 then -- Usar uncovered_lines_numbers
				local start_range = uncovered_lines_numbers[1] -- Usar uncovered_lines_numbers
				local prev_line = start_range

				for i = 2, #uncovered_lines_numbers do -- Usar uncovered_lines_numbers
					local current = uncovered_lines_numbers[i] -- Usar uncovered_lines_numbers
					if current > prev_line + 1 then
						-- El rango se ha roto, guardar el rango anterior
						if start_range == prev_line then
							table.insert(uncovered_ranges, tostring(start_range))
						else
							table.insert(uncovered_ranges, string.format("%d-%d", start_range, prev_line))
						end
						start_range = current
					end
					prev_line = current
				end

				-- Agregar el último rango
				if start_range == prev_line then
					table.insert(uncovered_ranges, tostring(start_range))
				else
					table.insert(uncovered_ranges, string.format("%d-%d", start_range, prev_line))
				end
			end

			-- Depuración para uncovered_lines en coverage_custom.lua (Comentado)
			-- if file_path == "src/App.js" or string.find(file_path, "App.js") then -- Para asegurar que capturamos App.js
			--   print(
			--     string.format(
			--       "DEBUG_CUSTOM_UNCOVERED_STATS: File: %s - stats.line_hits: %s - uncovered_lines_numbers: %s - uncovered_ranges: %s",
			--       file_path,
			--       vim.inspect(stats.line_hits),
			--       vim.inspect(uncovered_lines_numbers),
			--       vim.inspect(uncovered_ranges)
			--     )
			--   )
			-- end

			table.insert(items, {
				label = s_compact_summary, -- lo que se muestra como título
				text = s_compact_summary, -- texto para coincidir en la búsqueda
				value = ensure_string(full_edit_path), -- valor que se devuelve al seleccionar
				file = ensure_string(full_edit_path), -- ruta del archivo
				desc = s_detailed_description, -- descripción detallada
				_coverage_score = s_coverage_score, -- cobertura total para ordenamiento
				statements_score = string.format("%.1f", p_statements), -- porcentaje de statements
				branches_score = string.format("%.1f", p_branches), -- porcentaje de branches
				functions_score = string.format("%.1f", p_functions), -- porcentaje de functions
				uncovered_lines = table.concat(uncovered_ranges, ","), -- líneas no cubiertas
				search_text = search_text, -- texto optimizado para búsqueda
			})

			for k, v_stats in pairs(stats) do
				if total_coverage_stats[k] then
					total_coverage_stats[k].covered = total_coverage_stats[k].covered + v_stats.covered
					total_coverage_stats[k].total = total_coverage_stats[k].total + v_stats.total
				end
			end
		end
	end

	-- Ordenar items por coverage_score (menor a mayor)
	table.sort(items, function(a, b)
		-- Convertir de string a número para la comparación
		local score_a = tonumber(a._coverage_score) or 0
		local score_b = tonumber(b._coverage_score) or 0
		return score_a < score_b
	end)

	local overall_line_coverage_pct = pct(total_coverage_stats.lines.covered, total_coverage_stats.lines.total)
	local summary_label_str = string.format("📊 Total Global: %.1f%%", overall_line_coverage_pct)

	local function create_detailed_summary_text()
		local out = {}
		local order = { "lines", "statements", "branches", "functions" }
		for _, key in ipairs(order) do
			local stat = total_coverage_stats[key]
			if stat then
				local key_display = key:sub(1, 1):upper() .. key:sub(2)
				local uncovered = stat.total - stat.covered
				table.insert(
					out,
					string.format(
						"%s %.1f%% (%d/%d, %d unc.)",
						key_display,
						pct(stat.covered, stat.total),
						stat.covered,
						stat.total,
						uncovered
					)
				)
			end
		end
		return table.concat(out, "  |  ")
	end
	local summary_desc_str = create_detailed_summary_text()

	-- Asegurar que todas las partes del ítem de resumen sean cadenas para la búsqueda
	local s_summary_label = ensure_string(summary_label_str)
	local s_summary_desc = ensure_string(summary_desc_str)

	-- Calcular el porcentaje global total (media de todas las métricas)
	local global_coverage = (
		pct(total_coverage_stats.lines.covered, total_coverage_stats.lines.total)
		+ pct(total_coverage_stats.statements.covered, total_coverage_stats.statements.total)
		+ pct(total_coverage_stats.branches.covered, total_coverage_stats.branches.total)
		+ pct(total_coverage_stats.functions.covered, total_coverage_stats.functions.total)
	) / 4

	-- Crear el ítem de resumen con las métricas globales
	table.insert(items, 1, {
		label = s_summary_label,
		text = string.format("Total Coverage: %.1f%%", global_coverage),
		value = ensure_string("__SUMMARY_DO_NOT_EDIT__"),
		file = ensure_string("__SUMMARY_PLACEHOLDER__"),
		desc = s_summary_desc,
		_coverage_score = string.format("%.1f", global_coverage),
		statements_score = string.format(
			"%.1f",
			pct(total_coverage_stats.statements.covered, total_coverage_stats.statements.total)
		),
		branches_score = string.format(
			"%.1f",
			pct(total_coverage_stats.branches.covered, total_coverage_stats.branches.total)
		),
		functions_score = string.format(
			"%.1f",
			pct(total_coverage_stats.functions.covered, total_coverage_stats.functions.total)
		),
		search_text = ensure_string("Resumen Total Summary Overview " .. s_summary_label .. " " .. s_summary_desc),
	})

	-- Imprimir items para depuración (opcional, mantener comentado si no se necesita)
	-- print(vim.inspect(items))

	-- Importar y usar el módulo coverage_popup
	local coverage_popup = require("coverage.popup")
	coverage_popup.show(items) -- Llamada activa
end
return M
