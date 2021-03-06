import argparse
import junkdrawer
import os
import playsound
import random
import signal
import sqlite3
import sys
import threading
import time
import yaml

home_dir    = os.environ['HOME']
audio_dir   = f'{home_dir}/lib/audio'

class session(object):
  def __init__(self, database=f'{os.getenv("HOME")}/.config/sessions.sqlite'):
    args = self.cli_args()

    if args.database is not None:
      database = args.database

    if not os.path.isfile(database):
      print(f'Please create database: {database}')
      sys.exit(1)

    try:
      self._dbh = sqlite3.connect(database)
    except sqlite3.OperationalError as e:
      print(f'Error connecting to database: {e}')
      sys.exit(2)

    self.database = database

    # Mutable DB variables
    self._setters = [ 'sessions_owed' ]

    # By default, green light is active
    self._green = 1

    # Allow --nogreen to disable any green light potential
    if args.nogreen:
      self._green = 0

    # Flag to track if there was a chance to finish this session
    self.cum_chance = 0

    # Check to see how many sessions have been done in the cooldown window
    self.cooldown = self.check_cooldown()

    # only allow 1 'bonus' session
    if self.cooldown > 1:
      print('Only one bonus session allowed. Wait for cooldown.')
      sys.exit(1)

    # get the min / max number of edges from DB
    edges_min = int(self.get('edges_min'))
    edges_max = int(self.get('edges_max'))

    # increase min/max edges if doing a 'bonus' session
    if self.cooldown > 0:
      print('Bonus Session. Will not decrement session counter.')
      edges_min += 3
      edges_max += 3

    spread = abs(int(edges_min - edges_max))
    plus_minus = int(spread / 2)

    # If the spread is odd; e.g. 5, randomly pick 2 or 3 as the plus_minus
    if spread > (plus_minus * 2) and random.randint(0, 1) == 1:
      plus_minus = plus_minus + 1

    # set edges as middle value, then randomly add / remove
    # edges to favor the middle, but allow for the extremes
    edges = edges_min + int(spread / 2)

    for foo in range(1, plus_minus):
      # Randomly add an edge
      if random.randint(0, 2) == 1:
        edges = edges + 1

      # Randomly remove an edge
      if random.randint(0, 2) == 1:
        edges = edges - 1

    # set the session edge count
    self.edges_left = edges

    # Initialize counters
    self.edges_fail = 0
    self.edges_done = 0

    self.audio_dir = audio_dir

    self.goal_min = int(self.get('goal_min'))
    self.goal_max = int(self.get('goal_max'))

    # Allow --edges to override rolled edges; but only if more are requested
    if args.edges > self.edges_left:
      self.edges_left = args.edges

    # Log the session in the DB
    self.session_id = self.log_session()

    signal.signal(signal.SIGINT, self.sig_handler)

  def sig_handler(self, *args):
    self.end_session()

    print()
    print('Session Aborted!', file=sys.stderr)
    print()

    if self.edges_left > 0:
      self.add('sessions_owed')

    self._dbh.close()
    sys.exit(1)

  def log_session(self):
    # Get a session id
    query = 'insert into sessions (edges) values (?)'
    sth = self._dbh.cursor()
    sth.execute(query, (self.edges_left,))
    session_id = sth.lastrowid
    self._dbh.commit()

    return session_id

  def check_cooldown(self):
    # get the cooldown window
    window = str(self.get('cooldown_window'))

    # return number of sessions done in the cooldown window
    query = f'select count(*) from sessions where time > datetime(?, ?)'
    sth = self._dbh.cursor()
    sth.execute(query, ('now', f'-{window}'))
    count = int(sth.fetchone()[0])

    return count

  def end_session(self):
    left_plural = 'edge' if self.edges_left == 1 else 'edges'
    done_plural = 'edge' if self.edges_done == 1 else 'edges'
    fail_plural = 'edge' if self.edges_fail == 1 else 'edges'

    print()
    print(f'{self.edges_fail} {fail_plural} failed')
    print(f'{self.edges_done} {done_plural} done')
    print(f'{self.edges_left} {left_plural} left')

    query = ''' update sessions set cum_chance = ?, fail = ?,
                  done =?, left = ? where id = ?'''
    sth = self._dbh.cursor()
    sth.execute(query, (
            self.cum_chance,
            self.edges_fail,
            self.edges_done,
            self.edges_left,
            self.session_id,
          ))
    self._dbh.commit()

  def do_session(self):
    while self.edges_left > 0:
      elapsed = self.stroke()
      self.log_edge(elapsed)
      time.sleep(random.randint(3, 5))
      self.judge_edge(elapsed)
      self.edges_done += 1

      # Cool down
      time.sleep(random.randint(
                        int(self.get('cooldown_min')),
                        int(self.get('cooldown_max')),
                      ))
    print('  You may stop stroking your cock.')

    sound = self.choose_sound(f'{self.audio_dir}/stop')
    self.play_sound(sound)

    # don't decrement sessions_owed if on cooldown
    if self.cooldown == 0:
      self.sub('sessions_owed')

    # Current state of green light -- setting may have changed during play
    owed = int(self.get('sessions_owed'))
    green = int(self.get('enable_green')) and self._green
    if green and owed <= 0:
      self.finish()

    self.end_session()
    self._dbh.close()

  def get(self, key):
    query = 'select val from settings where key = ?'
    sth = self._dbh.cursor()
    sth.execute(query, (key,))
    val = sth.fetchone()

    if val is None:
      print(f'Value for key not stored: {key}', file=sys.stderr)
      return None
    else:
      return val[0]

  def set(self, key, val):
    query = 'update settings set val = ? where key = ?'
    sth = self._dbh.cursor()

    if key in self._setters:
      sth.execute(query, (val, key))
      self._dbh.commit()
    else:
      raise NameError(f'Key not accepted in set() method: {key}')

  def add(self, key, val = 1):
    temp = int(self.get(key))
    self.set(key, temp + val)

  def sub(self, key, val = 1):
    temp = int(self.get(key))
    self.set(key, temp - val)

  def finish(self):
    # Flip 3 coins
    coin1 = random.randint(0, 1)
    coin2 = random.randint(0, 1)
    coin3 = random.randint(0, 1)

    if coin1 and coin2 and coin3:
      print()
      print('Continue stroking your cock.')
      sound = self.choose_sound(f'{self.audio_dir}/continue')
      self.play_sound(sound, 0)

      # Fake out delay
      time.sleep(random.randint(3, 30))

      print('  GREEN LIGHT!')
      sound = self.choose_sound(f'{self.audio_dir}/finish')
      self.play_sound(sound, 0)

      time.sleep(random.randint(
                        int(self.get('green_min')),
                        int(self.get('green_max')),
                      ))

      sound = self.choose_sound(f'{self.audio_dir}/stop')
      self.play_sound(sound, 0)
      print()
      print('    Hands off your cock!')
      print()
      self.cum_chance = 1

  def stroke(self):
    if self.edges_done == 0:
      print('Start stroking your cock.')
      sound = self.choose_sound(f'{self.audio_dir}/start')
      self.play_sound(sound, 0)
    else:
      print()
      print('Continue stroking your cock.')
      sound = self.choose_sound(f'{self.audio_dir}/continue')
      self.play_sound(sound, 0)

    time.sleep(junkdrawer.fuzzy_weight(
                            int(self.get('stroke_min')),
                            int(self.get('stroke_max')),
                            int(self.get('stroke_skew')),
                          ))

    for null in range(0, 5):
      if random.randint(1, 8) == 1:
        sound = self.choose_sound(f'{self.audio_dir}/laugh')
        self.play_sound(sound, 0)
        time.sleep(random.randint(
                          int(self.get('stroke_add_min')),
                          int(self.get('stroke_add_max'))))

    print("  Don't Think. Just Edge.")
    sound = self.choose_sound(f'{self.audio_dir}/edge')
    self.play_sound(sound, 0)

    start = time.time()

    input("    Press 'Enter' once you get to the edge.")

    print("  Hands off your cock")
    sound = self.choose_sound(f'{self.audio_dir}/cooldown')
    self.play_sound(sound, 0)

    elapsed = time.time() - start

    return elapsed

  def log_edge(self, elapsed):
    query = 'insert into edges (session_id, to_edge, max) values (?, ?, ?)'
    sth = self._dbh.cursor()
    sth.execute(query, (self.session_id,
                        elapsed,
                        self.goal_max,
                      ))
    self._dbh.commit()

  def judge_edge(self, elapsed):
    if elapsed > self.goal_max:
      sound = self.choose_sound(f'{self.audio_dir}/slow')
      self.play_sound(sound, 0)
      self.edges_fail += 1
      print("    Too Slow. Try Again.")

      if self.edges_fail > 2:
        self.add('sessions_owed')

    else:
      sound = self.choose_sound(f'{self.audio_dir}/good')
      self.play_sound(sound, 0)
      self.edges_left -= 1
      print("    Good Boy!")

    if (elapsed > self.goal_min and elapsed < self.goal_max):
      self.goal_max = elapsed

  def cli_args(self):
    parser = argparse.ArgumentParser(
              description='A script to do edging sessions',
              epilog='-=-= Have fun. :D =-=-',
              formatter_class=argparse.MetavarTypeHelpFormatter)

    parser.add_argument(
      '--database',
      default=None,
      type=str,
      help='Path to the sqlite3 database to use',
    )

    parser.add_argument(
      '--nogreen',
      action='store_true',
      default=False,
      help='Disable green light'
    )

    parser.add_argument(
      '--edges',
      default=0,
      type=int,
      help='Specify the number of edges',
    )

    parser.add_argument(
      '--test',
      action='store_true',
      default=False,
      help="Don't play sounds, wait, or log sessions and edges",
    )

    return parser.parse_args()

  def choose_sound(self, directory):
    if os.path.isdir(directory):
      filename = ''

      while not os.path.isfile(f'{directory}/{filename}'):
        filename = random.choice(os.listdir(directory))

      return f'{directory}/{filename}'

    return None

  def play_sound(self, sound, blocking = 0):
    if sound is None:
      return

    if blocking == 1:
      playsound.playsound(sound)
    else:
      thread = threading.Thread(target = playsound.playsound, args = (sound,))
      thread.start()

    return
