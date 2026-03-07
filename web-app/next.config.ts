import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "export", // Makes next.js export as static files. No SSR
  distDir: "dist"
};

export default nextConfig;
