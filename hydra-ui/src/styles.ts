/**
 * Stylesheet entry point.
 *
 * `src/index.ts` deliberately does NOT import the CSS: doing so would make every
 * consumer pay for the full stylesheet even if they only import a hook, and would give
 * the main entry a side effect that defeats tree-shaking. This separate entry is what
 * produces the emitted CSS asset that `@hydra/ui/styles.css` resolves to.
 */
import "./styles/index.css";
