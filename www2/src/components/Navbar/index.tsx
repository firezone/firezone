'use client'
import { Navbar as FlowbiteNavbar } from 'flowbite-react'
import Image from 'next/image'

export default function Navbar() {
  return (
    <FlowbiteNavbar
      fluid={true}
      rounded={true}
    >
      <FlowbiteNavbar.Brand href="https://www.firezone.dev">
        <Image
          width={300}
          height={150}
          src="/logo.svg"
          className="mr-3 h-6 sm:h-9"
          alt="Firezone Logo"
        />
      </FlowbiteNavbar.Brand>
      <FlowbiteNavbar.Collapse>
        <FlowbiteNavbar.Link href="/docs">Docs</FlowbiteNavbar.Link>
        <FlowbiteNavbar.Link href="/contact/sales">Contact</FlowbiteNavbar.Link>
      </FlowbiteNavbar.Collapse>
    </FlowbiteNavbar>
  )
}
