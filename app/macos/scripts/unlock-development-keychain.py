"""Unlock the opted-in project keychain without putting its password in argv."""
import ctypes
import os
from pathlib import Path
import sys

folder = Path(sys.argv[1])
security = ctypes.CDLL('/System/Library/Frameworks/Security.framework/Security')
security.SecKeychainOpen.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
security.SecKeychainOpen.restype = ctypes.c_int32
security.SecKeychainUnlock.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_bool]
security.SecKeychainUnlock.restype = ctypes.c_int32
foundation = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
foundation.CFRelease.argtypes = [ctypes.c_void_p]
foundation.CFRelease.restype = None
keychain = ctypes.c_void_p()
status = security.SecKeychainOpen(os.fsencode(folder / 'development.keychain-db'), ctypes.byref(keychain))
if status:
    sys.exit(f'Cannot open development keychain (OSStatus {status}).')
try:
    password = (folder / 'password').read_bytes()
    status = security.SecKeychainUnlock(keychain, len(password), ctypes.c_char_p(password), True)
    if status:
        sys.exit(f'Cannot unlock development keychain (OSStatus {status}).')
finally:
    foundation.CFRelease(keychain)
