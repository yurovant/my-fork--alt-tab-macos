#!/usr/bin/env bash

set -exu

lastTag="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' | sort -V | tail -n 1 || true)"
if [[ -z "$lastTag" ]]; then
	version="0.0.1"
else
	currentVersion="${lastTag#v}"
	IFS='.' read -r major minor patch <<<"$currentVersion"
	version="$major.$minor.$((patch + 1))"
fi

echo "$version" > $VERSION_FILE
