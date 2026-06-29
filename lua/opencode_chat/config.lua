local M = {}

M.defaults = {
  command = "opencode",
  host = "127.0.0.1",
  port = nil,
  agent = "quick",
  model = "deepseek/deepseek-v4-flash",
  providers = {
    deepseek = {
      variants = { "low", "medium", "high", "max" },
      models = {
        { id = "deepseek-v4-flash", default_variant = "low" },
        { id = "deepseek-v4-pro", default_variant = "high" },
      },
    },
  },
  keymaps = {},
  root_markers = { ".root", ".git", ".svn", ".hg", ".project", ".ccls" },
  startup_timeout_ms = 5000,
  response_timeout_ms = 30000,
  ui = {
    width = 0.4,
    height = 0.85,
    input_height = 5,
    border = "rounded",
    title = " opencode-chat ",
    input_title = " prompt (<C-s> submit) ",
  },
}

local current = vim.deepcopy(M.defaults)
local selected = {
  providerID = nil,
  modelID = nil,
  variant = nil,
}

local function fail(message)
  error("opencode_chat config: " .. message, 3)
end

local function parse_model_ref(value)
  if type(value) ~= "string" then
    return nil, nil
  end
  local provider_id, model_id = value:match("^([^/]+)/(.+)$")
  return provider_id, model_id
end

local function list_contains(list, value)
  for _, item in ipairs(list or {}) do
    if item == value then
      return true
    end
  end
  return false
end

local function find_model(provider_id, model_id)
  local provider = current.providers and current.providers[provider_id]
  if not provider then
    return nil, nil
  end
  for _, model in ipairs(provider.models or {}) do
    if model.id == model_id then
      return provider, model
    end
  end
  return provider, nil
end

local function validate_provider(provider_id, provider)
  if type(provider) ~= "table" then
    fail("provider `" .. provider_id .. "` must be a table")
  end
  if type(provider.variants) ~= "table" or #provider.variants == 0 then
    fail("provider `" .. provider_id .. "` must define variants")
  end
  if type(provider.models) ~= "table" or #provider.models == 0 then
    fail("provider `" .. provider_id .. "` must define models")
  end
  for _, model in ipairs(provider.models) do
    if type(model) ~= "table" or type(model.id) ~= "string" or model.id == "" then
      fail("provider `" .. provider_id .. "` has invalid model")
    end
    if type(model.default_variant) ~= "string" or model.default_variant == "" then
      fail("model `" .. provider_id .. "/" .. model.id .. "` must define default_variant")
    end
    if not list_contains(provider.variants, model.default_variant) then
      fail("model `" .. provider_id .. "/" .. model.id .. "` default_variant must be in provider variants")
    end
  end
end

local function validate()
  if current.variant ~= nil then
    fail("top-level variant is no longer supported; use providers[provider].models[].default_variant")
  end
  if type(current.providers) ~= "table" then
    fail("providers must be a table")
  end
  for provider_id, provider in pairs(current.providers) do
    validate_provider(provider_id, provider)
  end
  local provider_id, model_id = parse_model_ref(current.model)
  if not provider_id or not model_id then
    fail("model must use provider/model format")
  end
  local provider, model = find_model(provider_id, model_id)
  if not provider or not model then
    fail("model `" .. current.model .. "` must exist in providers")
  end
  selected.providerID = provider_id
  selected.modelID = model_id
  selected.variant = model.default_variant
end

function M.setup(opts)
  local previous = current
  current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  local ok, err = pcall(validate)
  if not ok then
    current = previous
    error(err, 2)
  end
  return current
end

function M.get()
  return current
end

function M.current_model()
  return {
    providerID = selected.providerID,
    modelID = selected.modelID,
    variant = selected.variant,
  }
end

function M.model_ref(model)
  return model.providerID .. "/" .. model.modelID
end

function M.models()
  local out = {}
  for provider_id, provider in pairs(current.providers or {}) do
    for _, model in ipairs(provider.models or {}) do
      table.insert(out, {
        providerID = provider_id,
        modelID = model.id,
        default_variant = model.default_variant,
      })
    end
  end
  table.sort(out, function(a, b)
    if a.providerID == b.providerID then
      return a.modelID < b.modelID
    end
    return a.providerID < b.providerID
  end)
  return out
end

function M.variants(provider_id)
  local provider = current.providers and current.providers[provider_id or selected.providerID]
  return provider and vim.deepcopy(provider.variants) or {}
end

function M.select_model(provider_id, model_id)
  local provider, model = find_model(provider_id, model_id)
  if not provider or not model then
    return false, "model is not configured: " .. tostring(provider_id) .. "/" .. tostring(model_id)
  end
  selected.providerID = provider_id
  selected.modelID = model_id
  selected.variant = model.default_variant
  current.model = provider_id .. "/" .. model_id
  return true, M.current_model()
end

function M.select_variant(variant)
  local provider = current.providers and current.providers[selected.providerID]
  if not provider or not list_contains(provider.variants, variant) then
    return false, "variant is not configured for provider " .. tostring(selected.providerID) .. ": " .. tostring(variant)
  end
  selected.variant = variant
  return true, M.current_model()
end

function M._parse_model_ref(value)
  local provider_id, model_id = parse_model_ref(value)
  return { providerID = provider_id, modelID = model_id }
end

return M
