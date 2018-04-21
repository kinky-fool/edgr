user                kinky
database            ~/.config/edgr.sqlite
goal_under          240
goal_over           10
verbose             0

# Don't evaluate sessions not lasting at least /this/ long
too_short           30
# Number of days to evaluate
history             15
# Maximum sessions to evaluate
history_max         20

# Shortest a session can be
goal_min            300

# Longest a session can be
goal_max            1800

# Use defaults unless there are this many recorded sessions
min_sessions        5

lube_chance         20

prize_chance        60
prize_apply_chance  30

disarm_chance       42

script_file         /tmp/edgr.script
ctronome            ~/bin/ctronome
tick_file           ~/toys/tick.wav
tock_file           ~/toys/tock.wav

twitter_consumer_secret <consumer_secret>
twitter_consumer_key <consumer_key>
twitter_access_token <access_token>
twitter_access_token_secret <access_secret>
