import pytest


class _BaseStateMachine:

    """
    https://eth-brownie.readthedocs.io/en/stable/tests-hypothesis-stateful.html
    This base state machine class contains initialization of the system that all
    other tests need to start at (simple deployment).
    """

    def __init__(cls, a, cleanAUTO):
        cls.a = a
        cls.AUTO = cleanAUTO.AUTO
        cls.po = cleanAUTO.po
        cls.o = cleanAUTO.o
        cls.sm = cleanAUTO.sm
        cls.vf = cleanAUTO.vf
        cls.r = cleanAUTO.r
        cls.vf.setCaller(cleanAUTO.r, True, cleanAUTO.FR_DEPLOYER)
        cls.m = cleanAUTO.m


@pytest.fixture
def BaseStateMachine():
    yield _BaseStateMachine