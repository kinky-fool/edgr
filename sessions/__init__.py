import argparse
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
    self._setters = [ 'sessions_owed' ]

    self._user_id = 1

    # By default, green light is active
    self._green = 1

    # Allow --nogreen to disable any green light potential
    if args.nogreen:
      self._green = 0

    # Flag to track if there was a chance to finish this session
    self.cum_chance = 0

    edges_min = int(self.get('edges_min'))
    edges_max = int(self.get('edges_max'))

    # Do special things if Thong Game data used
    if args.percent and args.right and args.wrong:
      print('')

    # Set number of edges for this session
    self.edges_fail = 0
    self.edges_done = 0
    self.edges_left = random.randint(edges_min, edges_max)

    # Allow --edges to override rolled edges; but only if more are requested
    if args.edges > self.edges_left:
      self.edges_left = args.edges

    # Log the session in the DB
    self.session_id = self.log_session()

    signal.signal(signal.SIGINT, self.sig_handler)

  def sig_handler(self, *args):
    self.end_session()

    left_plural = 'edge' if self.edges_left == 1 else 'edges'
    done_plural = 'edge' if self.edges_done == 1 else 'edges'
    fail_plural = 'edge' if self.edges_fail == 1 else 'edges'

    print()
    print('Aborted Session!')
    print(f'{self.edges_fail} {fail_plural} failed')
    print(f'{self.edges_done} {done_plural} done')
    print(f'{self.edges_left} {left_plural} left')
    sys.exit(1)

  def log_session(self):
    # Get a session id
    query = 'insert into sessions (user_id, edges) values (?, ?)'
    sth = self._dbh.cursor()
    sth.execute(query, (self._user_id, self.edges))
    session_id = sth.lastrowid
    self._dbh.commit()

    return session_id

  def end_session(self):
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
    while self.edges > 0:
      self.stroke()

    owed = int(self.get('sessions_owed'))
    self.set('sessions_owed', owed - 1)

    if self.green:
      self.finish()
      self.cum_chance = 1

    self.end_session()

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

  def finish(self):
    print("Finish")

  def stroke(self):
    print("Edge")
    time.sleep(2)
    self.edges_done += 1
    self.edges_left -= 1

  @property
  def edges(self):
    return self.edges_left

  @property
  def green(self):
    # Current state of green light -- setting may have changed during play
    owed = int(self.get('sessions_owed'))
    green = int(self.get('enable_green')) and self._green
    if green and owed <= 0:
      return True

    return False

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
      'right',
      nargs='?',
      default=None,
      type=int,
      help='Longest streak of right guesses from Thong Game',
    )

    parser.add_argument(
      'wrong',
      nargs='?',
      default=None,
      type=int,
      help='Longest streak of wrong guesses from Thong Gmae',
    )

    parser.add_argument(
      'percent',
      nargs='?',
      default=None,
      type=float,
      help='Combined percent score from Thong Game',
    )

    return parser.parse_args()

