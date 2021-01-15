import os
import sys
import yaml

database=

class session(object):
  def __init__(self, database=f'{os.getenv("HOME")}/.config/sessions.sqlite'):

    try:
      self._dbh=sqlite3.connect(database)
    except:
      print(f'Error connecting to database')

    try:
      with open(config_file) as yamlfile:
        self._config = yaml.full_load(yamlfile)
    except IOError as err:
      print(f'Error reading file {config_file}: {err}')
    except FileNotFoundError:
      print(f'Please create "{config_file}" (see: {config_file}.example)')
      sys.exit(1)

    self._base_dir = base_dir
    self._setters = [ 'session' ]

  def get(self, name):
    if name not in self._config:
      return None
    else:
      return self._config[name]

  def set(self, name, val):
    if name in self._setters:
      self._config[name] = val
    else:
      raise NameError("name not accepted in set() method")
