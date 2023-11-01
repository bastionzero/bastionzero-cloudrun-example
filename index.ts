import { app } from './app.js';

const PORT = parseInt(process.env.PORT || "8080");

app.listen(PORT, () => console.log(`bastionzero-cloudrun-example listening on port ${PORT}`));