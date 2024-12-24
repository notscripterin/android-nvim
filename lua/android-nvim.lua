local window = nil

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
		local obj = vim.system({adb, "-s", id, "emu", "avd", "name"}, {}):wait()
		if obj.code == 0 then
			local read = obj.stdout or ""
			local device_name = read:match('^(.-)\n') or read
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
