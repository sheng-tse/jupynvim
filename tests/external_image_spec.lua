-- Headless contracts for external image resolution.
local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(here, ":p:h:h"))
local External = require("jupynvim.notebook.external_image")

assert(External.classify("http://example.test/a") == "http")
assert(External.classify("https://example.test/a") == "http")
assert(External.classify("./images/a.png") == "relative")
assert(External.classify("../images/a.jpg") == "relative")
assert(External.classify("data:image/png;base64,x") == nil)
assert(External.classify("/absolute/a.png") == nil)
print("1. source classification ok")

local png = "\137PNG\r\n\26\n" .. string.rep("x", 16)
local jpeg = "\255\216\255\224" .. string.rep("x", 16)
assert(External.detect_mime(png) == "image/png")
assert(External.detect_mime(jpeg) == "image/jpeg")
assert(External.detect_mime("not an image") == nil)
assert(External.resolve_path("/work/notebooks/a.ipynb", "../assets/a.jpg") == "/work/assets/a.jpg")
print("2. MIME signatures and notebook-relative paths ok")

local function await(test)
  assert(vim.wait(1000, test, 5), "timed out waiting for callback")
end

-- One HTTP process serves concurrent callers; successful result is cached.
External.clear_cache()
local starts, system_done = 0, nil
local function fake_system(argv, opts, done)
  starts = starts + 1
  assert(vim.deep_equal(argv, {
    "curl", "--location", "--fail", "--silent", "--show-error", "https://example.test/image",
  }), "HTTP argv changed")
  assert(opts.text == false)
  system_done = done
  return {}
end
local results = {}
for i = 1, 2 do
  External.resolve("https://example.test/image", { system = fake_system }, function(err, value)
    results[i] = { err = err, value = value }
  end)
end
assert(starts == 1, "duplicate in-flight HTTP request")
system_done({ code = 0, stdout = png, stderr = "" })
await(function() return #results == 2 end)
assert(results[1].value.mime == "image/png" and results[2].value.b64 == results[1].value.b64)
External.resolve("https://example.test/image", { system = fake_system }, function(err, value)
  results[3] = { err = err, value = value }
end)
await(function() return results[3] ~= nil end)
assert(starts == 1, "resolved URL did not use session cache")
print("3. async HTTP in-flight sharing and resolved cache ok")

-- Relative reads cross the notebook backend boundary and preserve JPEG MIME.
External.clear_cache()
local called, relative_result
local client = {
  call = function(_, method, args, callback)
    called = { method = method, args = args }
    callback(nil, { content_b64 = vim.base64.encode(jpeg), size = #jpeg })
  end,
}
External.resolve("./images/photo.jpg", {
  notebook_path = "/remote/project/notebooks/lesson.ipynb",
  client = client,
}, function(err, value)
  relative_result = { err = err, value = value }
end)
await(function() return relative_result ~= nil end)
assert(called.method == "fs_read")
assert(called.args.path == "/remote/project/notebooks/images/photo.jpg")
assert(relative_result.value.mime == "image/jpeg")
print("4. backend fs_read and JPEG MIME ok")

-- Invalid bytes fail once and remain negatively cached.
External.clear_cache()
local invalid_starts, invalid_results = 0, 0
local function invalid_system(_, _, done)
  invalid_starts = invalid_starts + 1
  done({ code = 0, stdout = "html response", stderr = "" })
  return {}
end
for _ = 1, 2 do
  External.resolve("https://example.test/invalid", { system = invalid_system }, function(err, value)
    assert(err and value == nil)
    invalid_results = invalid_results + 1
  end)
  await(function() return invalid_results > 0 end)
end
await(function() return invalid_results == 2 end)
assert(invalid_starts == 1, "failed image retried")
print("5. invalid image rejection and failure cache ok")

print("ALL EXTERNAL-IMAGE CHECKS PASSED")
vim.cmd("qa!")
