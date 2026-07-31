# Flight Radar — an Omarchy bar plugin

Live aircraft overhead on a micro-radar style scope, fed by the
[OpenSky Network](https://opensky-network.org).

A radar glyph sits in your bar. It carries a count badge when an aircraft is
overhead, and can raise a desktop notification as one arrives. Clicking it opens
a round scope with contacts drawn as heading triangles, in the colours of your
active Omarchy theme; clicking a contact opens it on the OpenSky flight map.

![Flight Radar](preview.png)

**No account needed.** It works out of the box on OpenSky's anonymous tier, and
with no coordinates configured it finds an approximate centre from your IP
address. Both can be improved from the panel's own settings — press **S** while
it is open — but neither is required.

## Install

```bash
omarchy plugin add https://github.com/yuters/omarchy-flight-radar
omarchy plugin enable yuters.flight-radar right
```

## Uninstall

```bash
omarchy plugin disable yuters.flight-radar
omarchy plugin remove yuters.flight-radar
```

## Attribution and terms

This plugin uses data from the OpenSky Network. Per their API documentation, work
built on that data should cite:

> Matthias Schäfer, Martin Strohmeier, Vincent Lenders, Ivan Martinovic and
> Matthias Wilhelm.
> **"Bringing Up OpenSky: A Large-scale ADS-B Sensor Network for Research."**
> In _Proceedings of the 13th IEEE/ACM International Symposium on Information
> Processing in Sensor Networks (IPSN)_, pages 83–94, April 2014.

```bibtex
@inproceedings{schafer2014bringing,
  title     = {Bringing Up OpenSky: A Large-scale ADS-B Sensor Network for Research},
  author    = {Sch{\"a}fer, Matthias and Strohmeier, Martin and Lenders, Vincent
               and Martinovic, Ivan and Wilhelm, Matthias},
  booktitle = {Proceedings of the 13th IEEE/ACM International Symposium on
               Information Processing in Sensor Networks (IPSN)},
  pages     = {83--94},
  year      = {2014},
  month     = {April}
}
```

**The OpenSky API is for research and non-commercial purposes.** Commercial use
requires their explicit permission — contact OpenSky if that applies to you.
OpenSky also blocks some IP ranges, cloud providers among them, in response to
misuse; if the radar cannot reach the API from a hosted environment, that is
expected and should be respected rather than worked around.

## Credits

- Scope design ported from [micro-radar](https://github.com/AnthonySturdy/micro-radar) by Anthony Sturdy
- Aircraft data from the [OpenSky Network](https://opensky-network.org), cited above
- Flight map links go to OpenSky's [tar1090](https://github.com/wiedehopf/tar1090) instance by wiedehopf
- Built for [Omarchy](https://omarchy.org) by DHH and contributors

## License

MIT — see [LICENSE](LICENSE).
