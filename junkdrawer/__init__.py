import random

def fuzzy_weight(minimum, maximum, skew):
  target = int(abs(maximum - minimum) * skew / 100)

  flip = 1
  if random.randint(0, 2) == 0:
    flip = -1

  result = target
  for i in range(0, target):
    if random.randint(0, 3) == 0:
      result += flip
    else:
      result -= flip

  return result
