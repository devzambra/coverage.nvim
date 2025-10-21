local M = {}

function M.setup()
	-- Configura autocmds aquí si quieres
	vim.api.nvim_create_autocmd("BufEnter", {
		pattern = "*.tsx, *.ts, *.jsx, *.js",
		callback = function()
			vim.cmd("silent! lua require('coverage.coverage').apply_coverage_highlights()")
		end,
	})
	vim.api.nvim_create_autocmd("BufWritePost", {
		pattern = "lcov.info",
		callback = function()
			vim.cmd("silent! lua require('coverage.coverage').apply_coverage_highlights()")
		end,
	})

	vim.api.nvim_create_user_command("CoverageRefresh", function()
		require("coverage.coverage").apply_coverage_highlights()
	end, {})

	vim.keymap.set("n", "<leader>tcs", function()
		require("coverage.coverage").show_coverage_summary()
	end, { desc = "Test Coverage Summary" })

	vim.keymap.set("n", "<leader>tcr", "<cmd>CoverageRefresh<CR>", { desc = "Coverage refresh highlights" })
	vim.keymap.set("n", "<leader>tct", function()
		require("coverage.coverage").toggle_coverage_highlights()
	end, { desc = "Coverage toggle highlights" })
end

return M
