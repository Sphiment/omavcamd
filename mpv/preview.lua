-- omavcam's preview bindings.
--
-- mpv is the only thing that knows when a drag on the preview begins and ends:
-- the compositor takes a Super drag before mpv is told anything, and it reports
-- neither the press nor the release to anyone else. So the left button is bound
-- here rather than left to mpv's own judgement about whether a click meant
-- "move me", and both edges of the press are put to use.
--
-- Down starts the drag and marks it, which is how the watcher tells a drag of
-- mpv's from one the compositor is doing. Up asks omavcam to place the window
-- immediately, so the snap happens as the button comes up rather than a
-- fraction of a second later once a poller has noticed the window stopped.

local cli = os.getenv("OMAVCAM_CLI")
local mark = os.getenv("OMAVCAM_DRAG_MARK")

local function run(...)
    -- Detached: mpv must not wait on omavcam, and omavcam must not care that
    -- mpv is the one asking.
    mp.command_native({ name = "subprocess", args = { ... }, playback_only = false, detach = true })
end

local function on_button(event)
    if event.event == "down" then
        if mark then
            run("touch", mark)
        end
        mp.commandv("begin-vo-dragging")
    elseif event.event == "up" and cli then
        run(cli, "preview", "snap", "now")
    end
end

mp.add_forced_key_binding("MBTN_LEFT", "omavcam-drag", on_button, { complex = true })

-- A lively drag should not put the preview fullscreen.
mp.add_forced_key_binding("MBTN_LEFT_DBL", "omavcam-no-fullscreen", function() end)
