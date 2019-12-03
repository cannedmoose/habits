
elm.js : src/Main.elm
	elm make src/Main.elm --output=elm.js

.PHONY: clean
clean:
	rm -rf ./elm-stuff elm.js --optimize

.PHONY: live
live:
	elm-live -h 0.0.0.0 src/Main.elm -- --output=elm.js --debug