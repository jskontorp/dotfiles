// Module shims for pi extension imports. Avoids requiring node_modules /
// package.json in the dotfiles repo while still letting `tsc --noEmit` check
// the first-party logic (typos, dead branches, removed imports).
//
// Keep these minimal — `any` is intentional. Real type definitions live in
// the upstream packages and the extensions are loaded by pi at runtime, not
// type-checked against the real signatures here.

declare module "@mariozechner/pi-coding-agent" {
  export type ExtensionAPI = any;
}

declare module "@sinclair/typebox" {
  export const Type: any;
}

// Node.js builtins used by the extensions. Without `@types/node` we declare
// the few subpaths we import.
declare module "node:child_process" {
  export function execFileSync(file: string, args?: readonly string[], options?: any): any;
}
declare module "node:os" {
  export function homedir(): string;
}
declare module "node:path" {
  export function join(...paths: string[]): string;
}
declare module "node:fs" {
  export function readFileSync(path: string, options?: any): any;
  export function existsSync(path: string): boolean;
  export function writeFileSync(path: string, data: any, options?: any): void;
}

// Globals the extensions reference at runtime (Node provides these; we don't
// pull @types/node).
declare const process: {
  env: Record<string, string | undefined>;
  [key: string]: any;
};
declare const fetch: any;
declare type AbortSignal = any;
declare const AbortSignal: any;
