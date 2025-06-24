local window = nil
local async = require "plenary.async"
local input = async.wrap(vim.ui.input, 2)
local select = async.wrap(vim.ui.select, 3)

local function trim(s)
	return s:gsub("^%s*(.-)%s*$", "%1")
end

local function find_gradlew(directory)
	local cwd = directory
	if cwd == nil then
		cwd = vim.fn.getcwd()
	end
	local parent = vim.fn.fnamemodify(cwd, ":h")

	local obj = vim.system({'find', cwd, "-maxdepth", "1", "-name", "gradlew"}, {}):wait()
	local result = obj.stdout

	if result == nil or #result == 0 then
		if cwd == parent then
			-- we reached root
			return nil
		end

		-- recursive call
		return find_gradlew(parent)
	end

	return { cwd = cwd, gradlew = trim(result) }
end

local apply_to_window = function(buf, data)
	if window == nil or data == nil then
		return 0, 0
	end

	local result = {}
	for line in data:gmatch("[^\n]+") do
		result[#result + 1] = line
	end

	local buffer_lines = vim.api.nvim_buf_line_count(buf) or 0

	vim.api.nvim_set_option_value("modifiable", true, {buf=buf})
	vim.api.nvim_buf_set_lines(buf, buffer_lines, buffer_lines + #data, false, result)
	vim.api.nvim_set_option_value("modifiable", false, {buf=buf})

	vim.api.nvim_win_set_cursor(window, {buffer_lines + #result, 0})

	return buffer_lines, buffer_lines + #result
end

local function create_build_window()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("modifiable", false, {buf=buf})
	vim.api.nvim_set_option_value("buftype", 'nofile', {buf=buf})
	vim.api.nvim_set_option_value("bufhidden", 'wipe', {buf=buf})

	if window ~= nil and vim.api.nvim_win_is_valid(window) then
		vim.api.nvim_win_close(window, true)
	end

	window = vim.api.nvim_open_win(buf, true, {
		split="below",
		width=vim.o.columns,
		height=10,
		style="minimal"
	})

	return buf
end

local function build_release()
	local gradlew = find_gradlew().gradlew
	if gradlew == nil then
		vim.notify("Build failed: gradlew is not found.", vim.log.levels.ERROR, {})
		return
	end

	vim.notify("Building release...", vim.log.levels.INFO, {})

	local time_passed = 0
	local timer = vim.uv.new_timer()
	timer:start(
		1000,
		1000,
		vim.schedule_wrap(function()
			time_passed = time_passed + 1
			vim.notify("Building release for " .. time_passed .. " seconds.", vim.log.levels.INFO, {})
		end)
	)

	local buf = create_build_window()

	vim.system({ gradlew, "assembleRelease" }, {
		text = true,
		stdout = vim.schedule_wrap(function(_, data)
			apply_to_window(buf, data)
		end),
		stderr = vim.schedule_wrap(function(_, data)
			local start, finish = apply_to_window(buf, data)
			for line = start, finish do
				vim.api.nvim_buf_add_highlight(buf, -1, "Error", line, 0, -1)
			end
		end)
	}, vim.schedule_wrap(function(obj)
		timer:stop()
		if obj.code == 0 then
			vim.notify("Build successful.", vim.log.levels.INFO, {})
		else
			vim.notify("Build failed: " .. obj.stderr, vim.log.levels.ERROR, {})
		end
	end))
end

local function clean()
	local gradlew = find_gradlew()
	if gradlew == nil then
		vim.notify("Build failed: gradlew is not found.", vim.log.levels.ERROR, {})
		return
	end

	vim.system(
		{ gradlew.gradlew, "clean" },
		{ text = true },
		vim.schedule_wrap(function(obj)
			if obj.code == 0 then
				vim.notify("Clean successful.", vim.log.levels.INFO, {})
			else
				vim.notify("Clean failed.", vim.log.levels.ERROR, {})
			end
		end)
	)
end

local function get_adb_devices(adb)
	local ids = {}
	local obj = vim.system({ adb, "devices" }):wait()
	local read = obj.stdout or ""
	local rows = {}
	for row in string.gmatch(read, "[^\n]+") do
		table.insert(rows, row)
	end

	for i = 2, #rows do
		local items = {}
		for item in string.gmatch(rows[i], "%S+") do
			table.insert(items, item)
		end

		table.insert(ids, items[1])
	end
	return ids
end

local function get_device_names(adb, ids)
	local devices = {}
	for i = 1, #ids do
		local id = ids[i]
		local cmd
		if id:match("^emulator") then
			cmd = { adb, "-s", id, "emu", "avd", "name" }
		else
			cmd = { adb, "-s", id, "shell", "getprop", "ro.product.model" }
		end
		local obj = vim.system(cmd, {}):wait()
		if obj.code == 0 then
			local read = obj.stdout or ""
			local device_name = read:match("^(.-)\n") or read
			table.insert(devices, device_name)
		end
	end
	return devices

end

local function get_running_devices(adb)
	local devices = {}

	local adb_devices = get_adb_devices(adb)
	local device_names = get_device_names(adb, adb_devices)

	for i = 1, #adb_devices do
		table.insert(devices, {
			id = trim(adb_devices[i]),
			name = trim(device_names[i]),
		})
	end

	return devices
end

local function find_application_id(root_dir)
	local file_path = root_dir .. "/app/build.gradle"
	local file_path_kt = root_dir .. "/app/build.gradle.kts"

	local file = io.open(file_path, "r")
	if not file then
		file = io.open(file_path_kt, "r")
		if not file then
			return nil
		end
	end

	local content = file:read("*all")
	file:close()

	for line in content:gmatch("[^\r\n]+") do
		if line:find("applicationId") then
			local app_id = line:match(".*[\"']([^\"']+)[\"']")
			return app_id
		end
	end

	return nil
end

local function find_main_activity(adb, device_id, application_id)
	local obj = vim.system({adb, "-s", device_id, "shell", "cmd", "package", "resolve-activity", "--brief", application_id}, {}):wait()
	if obj.code ~= 0 then
		return nil
	end

	local read = obj.stdout or ""

	local result = nil
	for line in read:gmatch("[^\r\n]+") do
		result = line
	end

	if result == nil then
		return nil
	end
	return trim(result)
end


local function build_and_install(root_dir, gradle, adb, device)
	local buf = create_build_window()

	local time_passed = 0
	local timer = vim.uv.new_timer()
	timer:start(
		1000,
		1000,
		vim.schedule_wrap(function()
			time_passed = time_passed + 1
			vim.notify("Building for " .. time_passed .. " seconds.", vim.log.levels.INFO, {})
		end)
	)

	vim.system({ gradle, "assembleDebug" }, {
		text = true,
		stdout = vim.schedule_wrap(function(_, data)
			apply_to_window(buf, data)
		end),
		stderr = vim.schedule_wrap(function(_, data)
			local start, finish = apply_to_window(buf, data)
			for line = start, finish do
				vim.api.nvim_buf_add_highlight(buf, -1, "Error", line, 0, -1)
			end
		end)
	}, vim.schedule_wrap(function(obj)
		timer:stop()
		if obj.code ~= 0 then
			vim.notify("Build failed.", vim.log.levels.ERROR, {})
			return
		end

		-- Installing
		vim.notify("Installing...", vim.log.levels.INFO, {})
		local install_obj = vim.system({adb, '-s', device.id, "install", root_dir .. "/app/build/outputs/apk/debug/app-debug.apk"}, {}):wait()
		if install_obj.code ~= 0 then
			vim.notify("Installation failed: " .. install_obj.stderr, vim.log.levels.ERROR, {})
			return
		end

		-- Launch the app
		vim.notify("Launching...", vim.log.levels.INFO, {})
		local application_id = find_application_id(root_dir)
		if application_id == nil then
			vim.notify("Failed to launch application, did not find application id", vim.log.levels.ERROR, {})
			return
		end

		local main_activity = find_main_activity(adb, device.id, application_id)
		if main_activity == nil then
			vim.notify("Failed to launch application, did not find main activity", vim.log.levels.ERROR, {})
			return
		end

		local launch_obj = vim.system({adb, "-s", device.id, "shell", "am", "start", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", "-n", main_activity}, {}):wait()
		if launch_obj.code ~= 0 then
			vim.notify("Failed to launch application: " .. launch_obj.stderr, vim.log.levels.ERROR, {})
			return
		end

		vim.notify("Successfully built and launched the application!", vim.log.levels.INFO, {})

		vim.api.nvim_win_close(window, true)
	end))
end

local function build_and_run()
	local gradlew = find_gradlew()
	if gradlew == nil then
		vim.notify("Build failed: gradlew is not found.", vim.log.levels.ERROR, {})
		return
	end

	local android_sdk = vim.fn.expand(vim.fn.expand(vim.env.ANDROID_HOME or vim.g.android_sdk))
	if android_sdk == nil or #android_sdk == 0 then
		vim.notify("Android SDK is not defined.", vim.log.levels.ERROR, {})
		return
	end

	local adb = android_sdk .. "/platform-tools/adb"
	local running_devices = get_running_devices(adb)
	if #running_devices == 0 then
		vim.notify("Build failed: no devices are running.", vim.log.levels.WARN, {})
		return
	end

	vim.ui.select(running_devices, {
		prompt = "Select device to run on",
		format_item = function(item)
			return item.name
		end,
	}, function(choice)
		if choice then
			vim.notify("Device selected: " .. choice.name, vim.log.levels.INFO, {})
			build_and_install(gradlew.cwd, gradlew.gradlew, adb, choice)
		else
			vim.notify("Build cancelled.", vim.log.levels.WARN, {})
		end
	end)
end

local function uninstall()
	local gradlew = find_gradlew()
	if gradlew == nil then
		vim.notify("Uninstall failed: gradlew is not found.", vim.log.levels.ERROR, {})
		return
	end

	local application_id = find_application_id(gradlew.cwd)
	if gradlew == nil then
		vim.notify("Uninstall failed: could not find application id.", vim.log.levels.ERROR, {})
		return
	end

	local android_sdk = vim.fn.expand(vim.fn.expand(vim.env.ANDROID_HOME or vim.g.android_sdk))
	if android_sdk == nil or #android_sdk == 0 then
		vim.notify("Android SDK is not defined.", vim.log.levels.ERROR, {})
		return
	end

	local adb = android_sdk .. "/platform-tools/adb"
	local running_devices = get_running_devices(adb)
	if #running_devices == 0 then
		vim.notify("Uninstall failed: no devices are running.", vim.log.levels.WARN, {})
		return
	end

	vim.ui.select(running_devices, {
		prompt = "Select device to uninstall from",
		format_item = function(item)
			return item.name
		end,
	}, function(choice)
		if choice then
			vim.notify("Device selected: " .. choice.name, vim.log.levels.INFO, {})
			local uninstall_obj = vim.system({adb, "-s", choice.id, "uninstall", application_id}, {}):wait()
			if uninstall_obj.code == 0 then
				vim.notify("Uninstall successful.", vim.log.levels.INFO, {})
			else
				vim.notify("Uninstall failed: " .. uninstall_obj.stderr, vim.log.levels.ERROR, {})
			end
		else
			vim.notify("Uninstall cancelled.", vim.log.levels.WARN, {})
		end
	end)
end

local function launch_avd()
	local android_sdk = vim.fn.expand(vim.fn.expand(vim.env.ANDROID_HOME or vim.g.android_sdk))
	local emulator = android_sdk .. "/emulator/emulator"

	local avds_obj = vim.system({ emulator, "-list-avds" }, {}):wait()
	if avds_obj.code ~= 0 then
		vim.notify("Cannot read emulators", vim.log.levels.WARN, {})
		return
	end

	local read = avds_obj.stdout or ""
	local avds = {}
	for line in read:gmatch("[^\r\n]+") do
		table.insert(avds, line)
	end
	table.remove(avds, 1)

	vim.ui.select(avds, {
		prompt = "AVD to start",
	}, function(choice)
		if choice then
			vim.notify("Device selected: " .. choice .. ". Launching!", vim.log.levels.INFO, {})
			vim.system({ emulator, "@" .. choice }, { text = true }, vim.schedule_wrap(function(obj)
				if obj.code ~= 0 then
					vim.notify("Launch failed: " .. obj.stderr, vim.log.levels.WARN, {})
				end
			end))
		else
			vim.notify("Launch cancelled.", vim.log.levels.WARN, {})
		end
	end)
end

local function refresh_dependencies()
	local gradlew = find_gradlew()
	if gradlew == nil then
		vim.notify("Refreshing dependencies failed, not able to find gradlew", vim.log.levels.ERROR, {})
		return
	end

	vim.notify("Refreshing dependencies", vim.log.levels.INFO, {})
	vim.system({gradlew.gradlew, "--refresh-dependencies"}, {}, vim.schedule_wrap(function(obj)
		if obj.code ~= 0 then
			vim.notify("Refreshing dependencies failed: " .. obj.stderr, vim.log.levels.ERROR, {})
			return
		end
		vim.notify("Refreshing dependencies sucessfully", vim.log.levels.INFO, {})
	end))
end

local function get_templates()
    local templates_root
    for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
        if path:match "android%-nvim" then
            templates_root = path .. "/templates"
            break
        end
    end
    local templates = vim.fn.readdir(templates_root)
    return templates, templates_root
end

local function match_and_replace(match, replace, file)
    local lines = vim.fn.readfile(file)
    local changed = false
    for i, line in ipairs(lines) do
        if line:match(match) then
            lines[i] = line:gsub(match, replace)
            changed = true
        end
    end
    if changed then
        vim.fn.writefile(lines, file)
    end
end

local function get_main_activity_path(path)
    local java_root = path .. "/app/src/main/java"

    local function search(dir)
        for _, entry in ipairs(vim.fn.readdir(dir)) do
            local full_path = dir .. "/" .. entry
            if vim.fn.isdirectory(full_path) == 1 then
                local found = search(full_path)
                if found then
                    return found
                end
            elseif entry == "MainActivity.kt" then
                return full_path
            end
        end
        return nil
    end

    return search(java_root)
end

local function get_package_name(main_activity_path)
    if not main_activity_path then
        return nil
    end

    for _, line in ipairs(vim.fn.readfile(main_activity_path)) do
        local pkg = line:match "^%s*package%s+([%w%.]+)"
        if pkg then
            return pkg
        end
    end

    return nil
end

local function update_template(name, package, template, template_package)
    local root = name
    local package_path = package:gsub("%.", "/")
    local template_package_path = template_package:gsub("%.", "/")
    local main_path = root .. "/app/src/main/java/" .. package_path
    local test_path = root .. "/app/src/test/java/" .. package_path
    local android_test_path = root .. "/app/src/androidTest/java/" .. package_path
    local template_path = root .. "/app/src/main/java/" .. template_package_path
    local template_test_path = root .. "/app/src/test/java/" .. template_package_path
    local template_android_test_path = root .. "/app/src/androidTest/java/" .. template_package_path
    local settings_file = root .. "/settings.gradle.kts"
    local gradle_file = root .. "/app/build.gradle.kts"
    local manifest_file = root .. "/app/src/main/AndroidManifest.xml"
    local mainactivity_file = main_path .. "/MainActivity.kt"
    local theme_file = main_path .. "/ui/theme/Theme.kt"
    local example_unit_test_file = test_path .. "/ExampleUnitTest.kt"
    local example_instrumented_test_file = android_test_path .. "/ExampleInstrumentedTest.kt"

    local theme = name .. "Theme"
    local template_theme = template .. "Theme"
    local theme_import = package .. ".ui.theme." .. theme
    local template_theme_import = template_package .. ".ui.theme." .. template_theme

    vim.fn.mkdir(main_path, "p")
    vim.fn.mkdir(test_path, "p")
    vim.fn.mkdir(android_test_path, "p")

    local files = vim.fn.readdir(template_path)
    for _, file in ipairs(files) do
        local from = template_path .. "/" .. file
        local to = main_path .. "/" .. file
        vim.fn.rename(from, to)
    end
    local test_files = vim.fn.readdir(template_test_path)
    for _, file in ipairs(test_files) do
        local from = template_test_path .. "/" .. file
        local to = test_path .. "/" .. file
        vim.fn.rename(from, to)
    end
    local android_test_files = vim.fn.readdir(template_android_test_path)
    for _, file in ipairs(android_test_files) do
        local from = template_android_test_path .. "/" .. file
        local to = android_test_path .. "/" .. file
        vim.fn.rename(from, to)
    end

    vim.fn.delete(template_path, "d")
    vim.fn.delete(template_test_path, "d")
    vim.fn.delete(template_android_test_path, "d")

    match_and_replace(template, name, settings_file)
    match_and_replace(template_package, package, gradle_file)
    match_and_replace(template, name, manifest_file)
    match_and_replace(template_package, package, mainactivity_file)
    match_and_replace(template_package, package, theme_file)
    match_and_replace(template_package, package, example_unit_test_file)
    match_and_replace(template_package, package, example_instrumented_test_file)
    match_and_replace(template_theme_import, theme_import, mainactivity_file)
    match_and_replace(template_theme, theme, mainactivity_file)
    match_and_replace(template_theme, theme, theme_file)
end

local function create_new_compose()
    local templates, templates_root = get_templates()

    if #templates == 0 then
        vim.notify("No templates found in: " .. templates_root, vim.log.levels.ERROR)
        return
    end

    async.run(function()
        local template = select(templates, { prompt = "Select a template: " })
        local name = input { prompt = "App name: " }
        local package = input { prompt = "Package (e.g., org.example.myapp): " }
        return name, package, template
    end, function(name, package, template)
        local project_root = vim.fn.getcwd() .. "/" .. name
        local template_root = templates_root .. "/" .. template
        local template_main_activity_path = get_main_activity_path(template_root)
        local template_package = get_package_name(template_main_activity_path)

        if vim.fn.isdirectory(project_root) == 1 then
            vim.notify("Project already exists at: " .. project_root, vim.log.levels.WARN)
            return
        end

        vim.fn.mkdir(project_root, "p")
        vim.fn.system("cp -a " .. template_root .. "/. " .. project_root)
        update_template(name, package, template, template_package)
        local main_activity_path = get_main_activity_path(project_root)

        vim.cmd("cd " .. vim.fn.fnameescape(project_root))
        if main_activity_path then
            vim.cmd("edit " .. vim.fn.fnameescape(main_activity_path))
        else
            vim.notify("MainActivity.kt not found", vim.log.levels.WARN)
        end
        
        vim.notify(main_activity_path, vim.log.levels.INFO)
        vim.notify("Project created at ./" .. name, vim.log.levels.INFO)
    end)
end

local function setup()
	vim.api.nvim_create_user_command("AndroidBuildRelease", function()
		build_release()
	end, {})

	vim.api.nvim_create_user_command("AndroidRun", function()
		build_and_run()
	end, {})

	vim.api.nvim_create_user_command("AndroidUninstall", function()
		uninstall()
	end, {})

	vim.api.nvim_create_user_command("AndroidClean", function()
		clean()
	end, {})

	vim.api.nvim_create_user_command("AndroidRefreshDependencies", function()
		refresh_dependencies()
	end, {})

	vim.api.nvim_create_user_command("LaunchAvd", function()
		launch_avd()
	end, {})

	vim.api.nvim_create_user_command("AndroidNew", function()
                create_new_compose()
        end, {})
end

return {
	setup = setup,
	build_release = build_release,
	build_and_run = build_and_run,
	refresh_dependencies = refresh_dependencies,
	launch_avd = launch_avd,
	clean = clean,
	uninstall = uninstall
}
