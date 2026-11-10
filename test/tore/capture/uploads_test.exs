defmodule Tore.Capture.UploadsTest do
  use Tore.DataCase, async: false

  alias Tore.Capture.Uploads

  setup do
    %{scope: scope_fixture()}
  end

  test "content_hash/1 is sha-256 hex of the bytes" do
    assert Uploads.content_hash("hello") ==
             "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
  end

  test "record/4 returns :ok on first upload and :duplicate on a repeat", %{scope: scope} do
    hash = Uploads.content_hash(<<1, 2, 3>>)

    assert {:ok, "kr_001"} = Uploads.record(scope, hash, "kr_001", "receipt")
    assert {:duplicate, "kr_001"} = Uploads.record(scope, hash, "kr_002", "receipt")
  end

  test "different households can upload the same bytes", %{scope: scope} do
    other = scope_fixture(household_fixture())
    hash = Uploads.content_hash(<<9, 9, 9>>)

    assert {:ok, _} = Uploads.record(scope, hash, "kr_010", "receipt")
    assert {:ok, _} = Uploads.record(other, hash, "kr_011", "receipt")
  end

  test "already_uploaded?/2 surfaces the original stream_id", %{scope: scope} do
    hash = Uploads.content_hash(<<5, 5, 5>>)
    Uploads.record(scope, hash, "kr_020", "shelf")

    assert {:ok, "kr_020"} = Uploads.already_uploaded?(scope, hash)
    assert :fresh = Uploads.already_uploaded?(scope, "0" |> String.duplicate(64))
  end
end
