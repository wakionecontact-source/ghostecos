# V2 model picker

`model-picker.js` and `model-picker.css` add catalog search, cross-provider results, category filters, creator marks, model ratings, and unavailable-model states to the deployed V2 page.

The model API does not provide individual model portraits. Creator logos are used where available, with local monogram SVGs as fallbacks. Brand SVGs were downloaded from the [Simple Icons](https://github.com/simple-icons/simple-icons) v16 package and are served from this site's `/gemo/v2/assets/models/` directory; the Simple Icons project asks users to read its legal disclaimer, and the marks remain associated with their respective owners.

The public `/v2/gemo` page is served from `/var/www/ghogem/v2/`. The existing workspace `index.html` in this directory is a separate prototype, so the live page's script and stylesheet includes are kept as a small production deployment patch rather than replacing that prototype.
