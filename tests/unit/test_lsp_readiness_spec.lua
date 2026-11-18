local eq = assert.are.same
local test_utils = require("tests.test_utils")

describe("executor LSP readiness", function()
  local config = require("lensline.config")
  local created_buffers = {}
  local client

  local function reset_modules()
    for name, _ in pairs(package.loaded) do
      if name:match("^lensline") then package.loaded[name] = nil end
    end
    config = require("lensline.config")
  end

  before_each(function()
    reset_modules()
    created_buffers = {}
    client = { id = 42, name = "roslyn_ls", handlers = {} }
    config.setup({
      debounce_ms = 5,
      lsp_readiness = { roslyn_ls = "workspace/projectInitializationComplete" },
      providers = { { name = "p_ready", enabled = true } },
      style = { use_nerdfont = false },
    })
  end)

  after_each(function()
    for _, bufnr in ipairs(created_buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    reset_modules()
  end)

  it("wraps the configured notification and calls the original handler", function()
    local handler_calls = 0
    local rendered = nil
    local original_calls = 0
    local bufnr = vim.api.nvim_create_buf(false, true)
    table.insert(created_buffers, bufnr)

    client.handlers["workspace/projectInitializationComplete"] = function()
      original_calls = original_calls + 1
      return "original"
    end

    test_utils.with_stub("lensline.providers", {
      get_enabled_providers = function()
        return {
          p_ready = {
            module = {
              name = "p_ready",
              handler = function(_, func_info, _, _)
                handler_calls = handler_calls + 1
                return { line = func_info.line, text = "ready" }
              end,
            },
            config = {},
          },
        }
      end,
    }, function()
      test_utils.with_stub("lensline.lens_explorer", {
        get_lsp_clients = function()
          return { client }
        end,
        discover_functions_async = function(_, _, _, cb)
          cb({ { line = 1, end_line = 1, name = "value" } })
        end,
        cleanup_cache = function() end,
        function_cache = {},
      }, function()
        test_utils.with_stub("lensline.renderer", {
          render_provider_lenses = function(_, _, items)
            rendered = items
          end,
          namespace = vim.api.nvim_create_namespace("dummy_lsp_ready_wrap"),
        }, function()
          test_utils.with_stub("lensline.limits", {
            should_skip = function() return false end,
            should_skip_lenses = function() return false end,
          }, function()
            test_utils.stub_debug_silent()
            test_utils.with_enabled_config(config, function()
              local executor = require("lensline.executor")
              local original_get_client = vim.lsp.get_client_by_id
              vim.lsp.get_client_by_id = function()
                return client
              end
              executor.setup_lsp_readiness_listeners()
              vim.api.nvim_exec_autocmds("LspAttach", {
                buffer = bufnr,
                data = { client_id = client.id },
              })
              vim.lsp.get_client_by_id = original_get_client

              executor.trigger_unified_update(bufnr)
              vim.wait(50)
              eq(0, handler_calls, "Providers should not run before the notification")

              local ret = client.handlers["workspace/projectInitializationComplete"](nil, nil, {
                client_id = client.id,
              })
              vim.wait(200, function() return handler_calls > 0 end)

              eq(1, original_calls, "Original notification handler should still run")
              eq("original", ret, "Original notification handler result should be preserved")
              eq(1, handler_calls, "Providers should run after the notification")
              eq({ { line = 1, text = "ready" } }, rendered)
              executor.cleanup_lsp_readiness_listeners()
            end)
          end)
        end)
      end)
    end)
  end)

  it("defers providers until the configured LSP reports readiness", function()
    local handler_calls = 0
    local rendered = nil
    local bufnr = vim.api.nvim_create_buf(false, true)
    table.insert(created_buffers, bufnr)

    test_utils.with_stub("lensline.providers", {
      get_enabled_providers = function()
        return {
          p_ready = {
            module = {
              name = "p_ready",
              handler = function(_, func_info, _, _)
                handler_calls = handler_calls + 1
                return { line = func_info.line, text = "ready" }
              end,
            },
            config = {},
          },
        }
      end,
    }, function()
      test_utils.with_stub("lensline.lens_explorer", {
        get_lsp_clients = function()
          return { client }
        end,
        discover_functions_async = function(_, _, _, cb)
          cb({ { line = 1, end_line = 1, name = "value" } })
        end,
        cleanup_cache = function() end,
        function_cache = {},
      }, function()
        test_utils.with_stub("lensline.renderer", {
          render_provider_lenses = function(_, _, items)
            rendered = items
          end,
          namespace = vim.api.nvim_create_namespace("dummy_lsp_ready"),
        }, function()
          test_utils.with_stub("lensline.limits", {
            should_skip = function() return false end,
            should_skip_lenses = function() return false end,
          }, function()
            test_utils.stub_debug_silent()
            test_utils.with_enabled_config(config, function()
              local executor = require("lensline.executor")

              executor.trigger_unified_update(bufnr)
              vim.wait(50)
              eq(0, handler_calls, "Providers should not run before LSP readiness")

              executor.mark_lsp_ready(client.id)
              vim.wait(200, function() return handler_calls > 0 end)

              eq(1, handler_calls, "Providers should run once after LSP readiness")
              eq({ { line = 1, text = "ready" } }, rendered)
            end)
          end)
        end)
      end)
    end)
  end)
end)
