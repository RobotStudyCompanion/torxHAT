#!/usr/bin/env python3
"""Button + LED test rig for the RSC front panel.

BUTTON  (GPIO23) idles low, goes high on press.
LED_PWM (GPIO24) drives the arcade button's LED through Q1.
RING    (GPIO12) drives 16x SKC6812 RGBW NeoPixel ring via J6.
"""

import board, neopixel, argparse, subprocess, atexit, time, threading
import pigpio
from gpiozero import Button, PWMLED
from signal import pause

BUTTON_PIN  = 23
LED_PIN     = 24
BOUNCE_TIME = 0.05
HOLD_TIME   = 1
RING_PIN    = board.D12   # M1_PWM via J6 servo connector
RING_COUNT  = 16          # SKC6812 RGBW 16-pixel ring

SERVO_PINS  = [13, 26]    # M2_PWM (J7/left), M3_PWM (J8/right)
SERVO_STOP  = 1500        # µs — neutral

SERVO_R_TRIM = 105   # µs — increase to speed up right, decrease to slow it down


SERVO_L_FWD = 1600        # µs — left forward
SERVO_L_REV = 1400        # µs — left reverse
SERVO_R_FWD = 1400 - SERVO_R_TRIM   # = 1350
SERVO_R_REV = 1600 + SERVO_R_TRIM   # = 1650

class Behaviour:
    """Base class for a button/LED behaviour — override what you need."""

    def __init__(self, button, led, ring=None):
        self.button = button
        self.led    = led
        self.ring   = ring

    def on_press(self):   pass
    def on_release(self): pass
    def on_hold(self):    pass

    def attach(self):
        self.button.when_pressed  = self.on_press
        self.button.when_released = self.on_release
        self.button.when_held     = self.on_hold


class PrintOnly(Behaviour):
    """Original test — just log events."""

    def on_press(self):   print("pressed")
    def on_release(self): print("released")


class SolidWhileHeld(Behaviour):
    """Breathes when idle, goes solid while the button's down."""

    def attach(self):
        super().attach()
        self.led.pulse()

    def on_press(self):
        print("pressed")
        self.led.on()

    def on_release(self):
        print("released")
        self.led.pulse()


class BrightnessCycle(Behaviour):
    """Each press steps through a few brightness levels."""

    levels = [0.0, 0.25, 0.5, 0.75, 1.0]

    def __init__(self, button, led):
        super().__init__(button, led)
        self.index = 0

    def on_press(self):
        self.index = (self.index + 1) % len(self.levels)
        self.led.value = self.levels[self.index]
        print(f"brightness -> {self.levels[self.index]:.0%}")


class TapVsHold(Behaviour):
    """Distinguishes a quick tap from a long press."""

    def on_press(self):   print("pressed")
    def on_release(self): print("released")
    def on_hold(self):    print("held")


class RingColour(Behaviour):
    """Ring fills on press, clears on release. LED breathes throughout."""

    PRESS_COLOUR   = (0, 80, 255, 0)   # RGBW — blue, white channel off
    RELEASE_COLOUR = (0, 0, 0, 0)

    def attach(self):
        super().attach()
        self.led.pulse()
        if self.ring:
            self.ring.fill(self.RELEASE_COLOUR)
            self.ring.show()

    def on_press(self):
        print("pressed")
        if self.ring:
            self.ring.fill(self.PRESS_COLOUR)
            self.ring.show()

    def on_release(self):
        print("released")
        if self.ring:
            self.ring.fill(self.RELEASE_COLOUR)
            self.ring.show()


class RingSweep(Behaviour):
    """Sweeps a single pixel around the ring while held, clears on release."""

    COLOUR = (0, 80, 255, 0)   # RGBW — blue, white channel off
    _running = False

    def attach(self):
        super().attach()
        self.led.pulse()
        if self.ring:
            self.ring.fill((0, 0, 0, 0))
            self.ring.show()

    def on_press(self):
        print("pressed — sweeping")
        self._running = True
        if self.ring:
            self.ring.fill((0, 0, 0, 0))
            self.ring.show()
            def sweep():
                prev = 0
                while self._running:
                    for i in range(len(self.ring)):
                        if not self._running:
                            break
                        self.ring[prev] = (0, 0, 0, 0)
                        self.ring[i]    = self.COLOUR
                        self.ring.show()
                        prev = i
                        time.sleep(0.06)
            threading.Thread(target=sweep, daemon=True).start()

    def on_release(self):
        print("released")
        self._running = False
        if self.ring:
            self.ring.fill((0, 0, 0, 0))
            self.ring.show()


class ServoBase(Behaviour):
    """Shared servo helpers — subclasses get self.pi if pigpio connected."""

    def __init__(self, button, led, ring=None, pi=None):
        super().__init__(button, led, ring)
        self.pi = pi

    def _set(self, l_pw, r_pw):
        if self.pi and self.pi.connected:
            self.pi.set_servo_pulsewidth(SERVO_PINS[0], l_pw)
            self.pi.set_servo_pulsewidth(SERVO_PINS[1], r_pw)

    def _stop(self):
        self._set(SERVO_STOP, SERVO_STOP)
        time.sleep(0.1)
        if self.pi and self.pi.connected:
            for pin in SERVO_PINS:
                self.pi.set_servo_pulsewidth(pin, 0)


class ServoHold(ServoBase):
    """Both servos forward while held, stop on release. LED breathes."""

    def attach(self):
        super().attach()
        self.led.pulse()

    def on_press(self):
        print("servo — forward")
        self._set(SERVO_L_FWD, SERVO_R_FWD)

    def on_release(self):
        print("servo — stop")
        self._stop()


class ServoCycle(ServoBase):
    """Tap cycles both servos: forward → reverse → stop → repeat. LED breathes."""

    STATES = [
        (SERVO_L_FWD, SERVO_R_FWD, "forward"),
        (SERVO_L_REV, SERVO_R_REV, "reverse"),
        (SERVO_STOP,  SERVO_STOP,  "stop"),
    ]

    def __init__(self, button, led, ring=None, pi=None):
        super().__init__(button, led, ring, pi)
        self.index = 0

    def attach(self):
        super().attach()
        self.led.pulse()
        self._stop()

    def on_press(self):
        l_pw, r_pw, label = self.STATES[self.index]
        print(f"servo — {label}")
        if label == "stop":
            self._stop()
        else:
            self._set(l_pw, r_pw)
        self.index = (self.index + 1) % len(self.STATES)


class ServoHoldDir(ServoBase):
    """Press → forward, hold → reverse, release → stop. LED breathes."""

    def attach(self):
        super().attach()
        self.led.pulse()

    def on_press(self):
        print("servo — forward")
        self._set(SERVO_L_FWD, SERVO_R_FWD)

    def on_hold(self):
        print("servo — reverse")
        self._set(SERVO_L_REV, SERVO_R_REV)

    def on_release(self):
        print("servo — stop")
        self._stop()


BEHAVIOURS = {
    "print":       PrintOnly,
    "solid":       SolidWhileHeld,
    "brightness":  BrightnessCycle,
    "tap_hold":    TapVsHold,
    "ring":        RingColour,
    "sweep":       RingSweep,
    "servo_hold":  ServoHold,
    "servo_cycle": ServoCycle,
    "servo_dir":   ServoHoldDir,
}

RING_BEHAVIOURS  = {"ring", "sweep"}
SERVO_BEHAVIOURS = {"servo_hold", "servo_cycle", "servo_dir"}


def main():
    parser = argparse.ArgumentParser(description="RSC button/LED test rig")
    parser.add_argument(
        "behaviour",
        nargs="?",
        default="solid",
        choices=BEHAVIOURS.keys(),
        help="behaviour to run (default: solid)",
    )
    args = parser.parse_args()

    atexit.register(
        lambda: subprocess.run(
            ['pinctrl', 'set', str(LED_PIN), 'op', 'dl'], check=False
        )
    )

    button = Button(BUTTON_PIN, pull_up=False, bounce_time=BOUNCE_TIME, hold_time=HOLD_TIME)
    led    = PWMLED(LED_PIN)
    ring   = None
    pi     = None

    if args.behaviour in RING_BEHAVIOURS:
        try:
            ring = neopixel.NeoPixel(
                RING_PIN, RING_COUNT,
                brightness=0.3,
                auto_write=False,
                pixel_order=neopixel.GRBW,
            )
        except (ImportError, RuntimeError) as e:
            print(f"ring unavailable: {e}")

    if args.behaviour in SERVO_BEHAVIOURS:
        pi = pigpio.pi()
        if not pi.connected:
            print("pigpio not connected — is pigpiod running? (sudo pigpiod)")
            pi = None
        else:
            print(f"pigpio connected — servos on GPIO {SERVO_PINS}")

    # servo behaviours need pi passed as kwarg
    if args.behaviour in SERVO_BEHAVIOURS:
        behaviour = BEHAVIOURS[args.behaviour](button, led, ring, pi=pi)
    else:
        behaviour = BEHAVIOURS[args.behaviour](button, led, ring)

    behaviour.attach()

    print(f"running '{args.behaviour}' — ctrl-c to stop")
    try:
        pause()
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        button.close()
        led.off()
        subprocess.run(['pinctrl', 'set', '24', 'op', 'dl'], check=False)
        if ring:
            try:
                ring.fill((0, 0, 0, 0))
                ring.show()
            except Exception:
                pass
        if pi and pi.connected:
            for pin in SERVO_PINS:
                pi.set_servo_pulsewidth(pin, 0)
            pi.stop()

if __name__ == "__main__":
    main()