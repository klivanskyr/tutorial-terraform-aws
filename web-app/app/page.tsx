"use client";

import { useState } from "react";

export default function Page() {
  const [counter, setCounter] = useState<number>(0);

  return (
    <main className="flex flex-col items-center justify-center h-dvh">
      <h1>This is the static page</h1>
      <button className="border rounded-xl p-4 shadow-lg active:shadow-sm transition-all duration-75" onClick={() => setCounter(counter + 1)}>This button has been clicked {counter} times.</button>
    </main>
  )
}