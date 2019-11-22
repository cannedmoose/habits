
elm.js : src/Main.elm
	elm make src/Main.elm --output=elm.js

.PHONY: clean
clean:
	rm -rf ./elm-stuff elm.js