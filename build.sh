#!/bin/bash

stack build
stack exec site clean
stack exec site build
stack exec site watch
