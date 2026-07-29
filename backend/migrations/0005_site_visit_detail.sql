-- Which character/screen an in-app event refers to.
--
-- site_visits started as arrive/app_ready/leave, where the path alone said
-- everything. The in-app funnel events (character_tap, first_message,
-- login_gate) need to say *which* character, and overloading `path` for that
-- would corrupt the by-path grouping the arrival rows depend on.
ALTER TABLE site_visits ADD COLUMN detail TEXT;
