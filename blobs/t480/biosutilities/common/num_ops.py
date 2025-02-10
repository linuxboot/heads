#!/usr/bin/env python3
#coding=utf-8

"""
Copyright (C) 2022 Plato Mavropoulos
"""

# https://leancrew.com/all-this/2020/06/ordinals-in-python/ by Dr. Drang
def get_ordinal(number):
    s = ('th', 'st', 'nd', 'rd') + ('th',) * 10
    
    v = number % 100
    
    return f'{number}{s[v % 10]}' if v > 13 else f'{number}{s[v]}'
