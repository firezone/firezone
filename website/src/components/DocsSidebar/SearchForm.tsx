import KbSearch from "@/components/KbSearch";

export default function SearchForm() {
  return (
    <div className="px-2">
      <KbSearch excludePathRegex={new RegExp(/^\/kb/)} />
    </div>
  );
}
