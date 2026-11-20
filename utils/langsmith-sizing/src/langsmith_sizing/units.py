"""Unit conversions and float tolerances: the only numbers the code may spell out.

Each is arithmetic that is not a choice (bytes in a KiB, seconds in a day), so it is defined once
here and imported. tests/test_literals.py fails on any other number in the package; a number that
is a choice is a parameter (params.yaml), a citation, the chart or an input.
"""

KIB = 1024  # bytes: the unit the backend compares a field in, and Kubernetes' Ki
MIB = KIB * KIB
GIB = MIB * KIB
TIB = GIB * KIB
KILO = 1000  # KB to MB, millicores to cores
GB = KILO**3  # decimal gigabyte, bytes
TB = KILO**4  # decimal terabyte, bytes
GIB_TO_GB = GIB / GB
PERCENT = 100
SECONDS_PER_HOUR = 3600
SECONDS_PER_DAY = 86_400
EPSILON = 1e-9  # float noise: 20.000000001 pods is 20, a 99.9999999999% mix sums to 100
